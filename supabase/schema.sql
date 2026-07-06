-- ============================================================
-- LumoLend — Supabase schema
-- Tables: runs (saved pricing runs), leads (locked scenarios),
-- email_outbox (audit of every email attempt), mlos (loan
-- officer roster — routing happens here, never in the client)
-- Emails: sent directly from Postgres via pg_net -> Resend.
-- The Resend API key lives in Supabase Vault under 'resend_api_key'.
-- Bonzo: every run/lead is POSTed to the event hook stored in
-- Vault under 'bonzo_webhook_url' (skipped silently if unset).
-- ============================================================

create extension if not exists pg_net;

-- ---------- tables ----------
create table if not exists public.runs (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  file_id text,
  email text not null,
  name text,
  flow text,
  loan numeric,
  rate numeric,
  payment numeric,
  payload jsonb
);

create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  file_id text,
  first_name text not null,
  last_name text,
  email text not null,
  phone text,
  flow text,
  program text,
  loan numeric,
  rate_lo numeric,
  rate_hi numeric,
  status text not null default 'locked',
  lo_slug text,
  payload jsonb
);

create table if not exists public.email_outbox (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  to_email text,
  subject text,
  html text,
  kind text,
  sent boolean not null default false,
  resend_id text,
  error text
);

-- MLO roster. One row per officer; every new lead routes to an
-- active MLO server-side and the borrower learns who by email.
-- Add rows here as the team grows — no client code changes.
-- highlights: jsonb array of strings shown as the "why this MLO"
-- bullets in the matched email.
create table if not exists public.mlos (
  slug text primary key,
  name text not null,
  email text not null,
  nmls text,
  company text,
  highlights jsonb,
  active boolean not null default true
);
alter table public.mlos add column if not exists company text;
alter table public.mlos add column if not exists highlights jsonb;

insert into public.mlos (slug, name, email, nmls, company, highlights)
values ('m-alloo', 'Moh Alloo', 'alloo.mohamed@gmail.com', '2732105', 'West Capital Lending', jsonb_build_array(
  'Extensive finance background, including work experience at Amazon and Apple',
  'Top cash-out / lending expert at West Capital Lending',
  'Top 1% on-time closing record',
  'Access to a 90+ lender network',
  'Near-perfect 5-star customer rating'
))
on conflict (slug) do update
  set name = excluded.name, email = excluded.email, nmls = excluded.nmls,
      company = excluded.company, highlights = excluded.highlights;

-- ---------- row level security ----------
alter table public.runs enable row level security;
alter table public.leads enable row level security;
alter table public.email_outbox enable row level security;
alter table public.mlos enable row level security;

-- anonymous visitors may INSERT (write-only). Nobody anonymous can read.
drop policy if exists runs_anon_insert on public.runs;
create policy runs_anon_insert on public.runs for insert to anon with check (true);
drop policy if exists leads_anon_insert on public.leads;
create policy leads_anon_insert on public.leads for insert to anon with check (true);
drop policy if exists leads_anon_update on public.leads;
create policy leads_anon_update on public.leads for update to anon using (true) with check (true);

-- ---------- mlo routing ----------
-- Single-officer roster today: return the active MLO. When more
-- officers join, replace the body with flow/state-aware routing.
create or replace function public.pick_mlo(p_flow text)
returns public.mlos language sql stable as $$
  select * from public.mlos where active order by slug limit 1;
$$;

-- ---------- email sender ----------
-- Reads the Resend key from Vault. If absent, the email is queued
-- in email_outbox with sent=false and no error is raised.
drop function if exists public.send_email(text, text, text, text);
create or replace function public.send_email(p_to text, p_subject text, p_html text, p_kind text, p_cc text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_key text;
  v_outbox uuid;
  v_body jsonb;
begin
  insert into public.email_outbox (to_email, subject, html, kind)
  values (p_to, p_subject, p_html, p_kind)
  returning id into v_outbox;

  select decrypted_secret into v_key
  from vault.decrypted_secrets
  where name = 'resend_api_key'
  limit 1;

  if v_key is null then
    update public.email_outbox set error = 'resend_api_key not set in Vault' where id = v_outbox;
    return;
  end if;

  v_body := jsonb_build_object(
    'from', 'LumoLend Desk <desk@lumolend.com>',
    'to', jsonb_build_array(p_to),
    'subject', p_subject,
    'html', p_html
  );
  if p_cc is not null then
    v_body := v_body || jsonb_build_object('cc', jsonb_build_array(p_cc));
  end if;

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_key,
      'Content-Type', 'application/json'
    ),
    body := v_body
  );

  update public.email_outbox set sent = true where id = v_outbox;
end $$;

-- ---------- bonzo bridge ----------
-- POSTs the payload to the Bonzo event hook stored in Vault under
-- 'bonzo_webhook_url'. If the secret is unset, does nothing.
create or replace function public.post_to_bonzo(p_payload jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_url text;
begin
  select decrypted_secret into v_url
  from vault.decrypted_secrets
  where name = 'bonzo_webhook_url'
  limit 1;

  if v_url is null then return; end if;

  perform net.http_post(
    url := v_url,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := p_payload
  );
end $$;

-- ---------- triggers ----------
create or replace function public.on_new_run()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.send_email(
    new.email,
    'Your LumoLend run is saved',
    '<div style="font-family:sans-serif;max-width:560px"><h2>Your run is saved' ||
    coalesce(', ' || new.name, '') || '.</h2>' ||
    '<p>Pricing held exactly where you left it. Pick up any time:</p>' ||
    '<p><a href="https://lumolend.com" style="background:#00E67A;color:#04140B;padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold">RESUME MY RUN &rarr;</a></p>' ||
    '<p style="color:#777;font-size:12px">Indicative ranges, not an offer or commitment to lend. LumoLend, operated by Honest Casa LLC · NMLS #1566096 · Equal Housing Lender</p></div>',
    'run_saved'
  );
  perform public.send_email(
    'alloo.mohamed@gmail.com',
    'New saved run — ' || coalesce(new.name, new.email) || ' (' || coalesce(new.flow,'?') || ')',
    '<div style="font-family:sans-serif"><h3>New saved run</h3><p>' || coalesce(new.name,'(no name)') || ' · ' || new.email ||
    '</p><p>Flow: ' || coalesce(new.flow,'?') || ' · Loan: $' || coalesce(round(new.loan)::text,'?') || '</p></div>',
    'run_saved_internal'
  );
  perform public.post_to_bonzo(jsonb_build_object(
    'kind', 'run_saved',
    'email', new.email,
    'name', new.name,
    'flow', new.flow,
    'loan', new.loan,
    'rate', new.rate,
    'payment', new.payment,
    'payload', new.payload
  ));
  return new;
end $$;

drop trigger if exists trg_new_run on public.runs;
create trigger trg_new_run after insert on public.runs
for each row execute function public.on_new_run();

create or replace function public.on_new_lead()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_mlo public.mlos;
  v_first text;
  v_bullets text;
  v_matched text := '';
begin
  v_mlo := public.pick_mlo(new.flow);
  if v_mlo.slug is not null then
    update public.leads set lo_slug = v_mlo.slug where id = new.id;

    v_first := split_part(v_mlo.name, ' ', 1);
    select coalesce(string_agg('<li style="margin:6px 0">' || h || '</li>', ''), '')
      into v_bullets
      from jsonb_array_elements_text(coalesce(v_mlo.highlights, '[]'::jsonb)) h;

    v_matched :=
      '<p style="color:#B9C6CC;font-size:14px;line-height:1.75;margin:0 0 6px">You&rsquo;ve been matched with: <b style="color:#E9F4F6">' ||
      v_mlo.name || coalesce(' @ ' || v_mlo.company, '') || '</b> (CC&rsquo;d on this email). Here are a few reasons ' ||
      v_first || ' is the right fit:</p>' ||
      case when v_bullets <> '' then
      '<div style="background:#0C1218;border:1px solid #1B2833;border-radius:8px;padding:16px 22px;margin:14px 0 20px">' ||
      '<ul style="margin:0;padding-left:18px;color:#B9C6CC;font-size:13.5px;line-height:1.8">' || v_bullets || '</ul></div>'
      else '' end ||
      '<p style="color:#B9C6CC;font-size:14px;line-height:1.75">Look out for a text message or email from ' || v_first ||
      ' on next steps. In the meantime, don&rsquo;t be shy &mdash; reply to this email with any questions.</p>';
  end if;

  perform public.send_email(
    new.email,
    'You''ve been matched — your scenario is in review',
    '<div style="background:#05080C;padding:36px 18px;font-family:Arial,Helvetica,sans-serif">' ||
    '<div style="max-width:560px;margin:0 auto">' ||
    '<div style="font-size:15px;letter-spacing:6px;font-weight:bold;color:#E9F4F6;margin-bottom:26px">LUMO<span style="color:#5FE9FF">LEND</span></div>' ||
    '<h1 style="color:#E9F4F6;font-size:26px;margin:0 0 18px">You&rsquo;ve been matched.</h1>' ||
    '<p style="color:#B9C6CC;font-size:14px;line-height:1.75">' || new.first_name ||
    ' &mdash; congrats! Your scenario is locked and in review. Your loan officer will firm your numbers against the live lender panel and guide you through every step &mdash; nothing gets re-asked.</p>' ||
    v_matched ||
    '<div style="background:#0C1218;border:1px solid #1B2833;border-radius:8px;padding:14px 22px;margin:6px 0 22px">' ||
    '<span style="color:#7C8F99;font-size:10px;letter-spacing:2px">YOUR SCENARIO</span><br>' ||
    '<span style="color:#E9F4F6;font-size:13.5px;line-height:1.9">' || coalesce(new.program,'&mdash;') ||
    ' &middot; Loan <b style="color:#00E67A">$' || coalesce(round(new.loan)::text,'&mdash;') || '</b>' ||
    ' &middot; Indicative band <b style="color:#5FE9FF">' || coalesce(new.rate_lo::text,'&mdash;') || '% &ndash; ' || coalesce(new.rate_hi::text,'&mdash;') || '%</b></span></div>' ||
    '<p style="margin:0 0 28px"><a href="https://lumolend.com/preapprove.html" style="background:#00E67A;color:#04140B;padding:13px 26px;text-decoration:none;border-radius:4px;font-weight:bold;font-size:13px">CONTINUE MY REVIEW &rarr;</a></p>' ||
    '<p style="color:#B9C6CC;font-size:14px;line-height:1.7;margin:0 0 26px">Sincerely,<br><b style="color:#E9F4F6">The LumoLend Team</b></p>' ||
    '<p style="color:#3A4A54;font-size:11px;line-height:1.7;border-top:1px solid #1B2833;padding-top:14px;margin:0">Indicative ranges, not an offer or commitment to lend; subject to full underwriting. LumoLend, operated by Honest Casa LLC &middot; NMLS #1566096 &middot; Equal Housing Lender.</p>' ||
    '</div></div>',
    'lead_locked',
    v_mlo.email
  );
  perform public.send_email(
    coalesce(v_mlo.email, 'alloo.mohamed@gmail.com'),
    'LEAD: ' || new.first_name || ' ' || coalesce(new.last_name,'') || ' — ' || coalesce(new.flow,'?') || ' $' || coalesce(round(new.loan)::text,'?'),
    '<div style="font-family:sans-serif"><h3>New locked scenario — routed to you</h3>' ||
    '<p>' || new.first_name || ' ' || coalesce(new.last_name,'') || '<br>' || new.email || ' · ' || coalesce(new.phone,'no phone') || '</p>' ||
    '<p>Flow: ' || coalesce(new.flow,'?') || '<br>Program: ' || coalesce(new.program,'?') ||
    '<br>Loan: $' || coalesce(round(new.loan)::text,'?') || '<br>Band: ' || coalesce(new.rate_lo::text,'?') || '–' || coalesce(new.rate_hi::text,'?') || '%</p>' ||
    '<p>Full run JSON is in the leads table (file ' || coalesce(new.file_id,'?') || ').</p></div>',
    'lead_locked_internal'
  );
  perform public.post_to_bonzo(jsonb_build_object(
    'kind', 'lead_locked',
    'file_id', new.file_id,
    'first_name', new.first_name,
    'last_name', new.last_name,
    'email', new.email,
    'phone', new.phone,
    'flow', new.flow,
    'program', new.program,
    'loan', new.loan,
    'rate_lo', new.rate_lo,
    'rate_hi', new.rate_hi,
    'lo_slug', v_mlo.slug,
    'payload', new.payload
  ));
  return new;
end $$;

drop trigger if exists trg_new_lead on public.leads;
create trigger trg_new_lead after insert on public.leads
for each row execute function public.on_new_lead();

-- ============================================================
-- ACTIVATE INTEGRATIONS (manual steps, run once each):
-- Emails:  select vault.create_secret('YOUR_RESEND_API_KEY', 'resend_api_key');
-- Bonzo:   select vault.create_secret('YOUR_BONZO_EVENT_HOOK_URL', 'bonzo_webhook_url');
-- ============================================================
