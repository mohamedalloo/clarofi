-- ============================================================
-- LumoLend — Supabase schema
-- Tables: runs (saved pricing runs), leads (locked scenarios),
-- email_outbox (audit of every email attempt)
-- Emails: sent directly from Postgres via pg_net -> Resend.
-- The Resend API key lives in Supabase Vault under 'resend_api_key'.
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

-- ---------- row level security ----------
alter table public.runs enable row level security;
alter table public.leads enable row level security;
alter table public.email_outbox enable row level security;

-- anonymous visitors may INSERT (write-only). Nobody anonymous can read.
drop policy if exists runs_anon_insert on public.runs;
create policy runs_anon_insert on public.runs for insert to anon with check (true);
drop policy if exists leads_anon_insert on public.leads;
create policy leads_anon_insert on public.leads for insert to anon with check (true);
drop policy if exists leads_anon_update on public.leads;
create policy leads_anon_update on public.leads for update to anon using (true) with check (true);

-- ---------- email sender ----------
-- Reads the Resend key from Vault. If absent, the email is queued
-- in email_outbox with sent=false and no error is raised.
create or replace function public.send_email(p_to text, p_subject text, p_html text, p_kind text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_key text;
  v_outbox uuid;
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

  perform net.http_post(
    url := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_key,
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object(
      'from', 'LumoLend Desk <desk@lumolend.com>',
      'to', jsonb_build_array(p_to),
      'subject', p_subject,
      'html', p_html
    )
  );

  update public.email_outbox set sent = true where id = v_outbox;
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
  return new;
end $$;

drop trigger if exists trg_new_run on public.runs;
create trigger trg_new_run after insert on public.runs
for each row execute function public.on_new_run();

create or replace function public.on_new_lead()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.send_email(
    new.email,
    'Scenario locked — your loan officer is being assigned',
    '<div style="font-family:sans-serif;max-width:560px"><h2>' || new.first_name || ', your scenario is locked.</h2>' ||
    '<p>Program: <b>' || coalesce(new.program,'—') || '</b><br>Loan: <b>$' || coalesce(round(new.loan)::text,'—') ||
    '</b><br>Indicative band: <b>' || coalesce(new.rate_lo::text,'—') || '% – ' || coalesce(new.rate_hi::text,'—') || '%</b></p>' ||
    '<p>Next: verify in minutes, then unlock the loan officer curated for exactly this deal.</p>' ||
    '<p><a href="https://lumolend.com/preapprove.html" style="background:#00E67A;color:#04140B;padding:12px 24px;text-decoration:none;border-radius:4px;font-weight:bold">CONTINUE TO PRE-APPROVAL &rarr;</a></p>' ||
    '<p style="color:#777;font-size:12px">Indicative ranges, not an offer or commitment to lend. LumoLend · NMLS #2732105 · Equal Housing Lender</p></div>',
    'lead_locked'
  );
  perform public.send_email(
    'alloo.mohamed@gmail.com',
    'LEAD: ' || new.first_name || ' ' || coalesce(new.last_name,'') || ' — ' || coalesce(new.flow,'?') || ' $' || coalesce(round(new.loan)::text,'?'),
    '<div style="font-family:sans-serif"><h3>New locked scenario</h3>' ||
    '<p>' || new.first_name || ' ' || coalesce(new.last_name,'') || '<br>' || new.email || ' · ' || coalesce(new.phone,'no phone') || '</p>' ||
    '<p>Flow: ' || coalesce(new.flow,'?') || '<br>Program: ' || coalesce(new.program,'?') ||
    '<br>Loan: $' || coalesce(round(new.loan)::text,'?') || '<br>Band: ' || coalesce(new.rate_lo::text,'?') || '–' || coalesce(new.rate_hi::text,'?') || '%</p>' ||
    '<p>Full run JSON is in the leads table (file ' || coalesce(new.file_id,'?') || ').</p></div>',
    'lead_locked_internal'
  );
  return new;
end $$;

drop trigger if exists trg_new_lead on public.leads;
create trigger trg_new_lead after insert on public.leads
for each row execute function public.on_new_lead();

-- ============================================================
-- ACTIVATE EMAILS (one manual step, run once):
-- select vault.create_secret('YOUR_RESEND_API_KEY', 'resend_api_key');
-- ============================================================
