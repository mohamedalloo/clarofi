-- ============================================================
-- LumoLend Non-QM Rate Index — aggregate-only public RPC
-- Publishes monthly medians of indicative rates from pricing
-- runs. No row-level data, no PII: buckets under 5 runs are
-- suppressed entirely. The /rate-index/ page calls this via
-- POST /rest/v1/rpc/rate_index with the anon key.
-- Run once in the Supabase SQL editor (safe to re-run).
-- ============================================================

create or replace function public.rate_index()
returns table (
  month text,
  flow text,
  n bigint,
  median_rate numeric,
  p25_rate numeric,
  p75_rate numeric,
  median_loan numeric
)
language sql
stable
security definer
set search_path = public
as $$
  select
    to_char(date_trunc('month', created_at), 'YYYY-MM') as month,
    flow,
    count(*) as n,
    round((percentile_cont(0.5) within group (order by rate))::numeric, 3) as median_rate,
    round((percentile_cont(0.25) within group (order by rate))::numeric, 3) as p25_rate,
    round((percentile_cont(0.75) within group (order by rate))::numeric, 3) as p75_rate,
    round((percentile_cont(0.5) within group (order by loan))::numeric, 0) as median_loan
  from public.runs
  where rate is not null
    and rate between 3 and 15          -- guard against junk input
    and loan is not null and loan > 0
    and flow is not null
    and created_at >= date_trunc('month', now()) - interval '12 months'
  group by 1, 2
  having count(*) >= 5                 -- suppress thin buckets (privacy + statistical floor)
  order by 1 desc, 2;
$$;

revoke all on function public.rate_index() from public;
grant execute on function public.rate_index() to anon;
