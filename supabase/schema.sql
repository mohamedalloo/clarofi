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
create table if not exists public.mlos (
  slug text primary key,
  name text not null,
  email text not null,
  nmls text,
  active boolean not null default true
);

insert into public.mlos (slug, name, email, nmls)
values ('m-alloo', 'Mohamed Alloo', 'alloo.mohamed@gmail.com', '2732105')
on conflict (slug) do nothing;

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
    '<p style="color:#777;font-size:12px">Indicative ranges, not an offer to lend. LumoLend · NMLS #2732105 · Equal Housing Lender</p></div>',
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
begin
  v_mlo := public.pick_mlo(new.flow);
  if v_mlo.slug is not null then
    update public.leads set lo_slug = v_mlo.slug where id = new.id;
  end if;

  perform public.send_email(
    new.email,
    'Scenario locked — meet your loan officer',
    '<div style="font-family:sans-serif;max-width:560px"><h2>' || new.first_name || ', your scenario is locked.</h2>' ||
    '<p>Program: <b>' || coalesce(new.program,'—') || '</b><br>Loan: <b>$' || coalesce(round(new.loan)::text,'—') ||
    '</b><br>Indicative band: <b>' || coalesce(new.rate_lo::text,'—') || '% – ' || coalesce(new.rate_hi::text,'—') || '%</b></p>' ||
    coalesce('<p>Your loan officer is <b>' || v_mlo.name || '</b> (NMLS #' || coalesce(v_mlo.nmls,'—') ||
    '), copied on this email. Your full run transfers to them exactly as you built it — nothing gets re-asked.</p>', '') ||
    '<p>Next: verify in minutes to firm your pricing before the first call.</p>' ||
    '<p><a href="https://lumolend.com/preapprove.html" style="background:#00E67A;color:#04140B;padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold">CONTINUE TO PRE-APPROVAL &rarr;</a></p>' ||
    '<p style="color:#777;font-size:12px">Indicative ranges, not an offer or commitment to lend. LumoLend · NMLS #2732105 · Equal Housing Lender</p></div>',
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
