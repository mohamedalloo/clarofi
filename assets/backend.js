/* ============================================================
   LumoLend backend bridge — Supabase REST (no SDK, ~1KB)
   Reads config from assets/config.js (window.LUMO_CONFIG).
   Every function is fail-soft: the UX never blocks on the network.
   Emails are sent by Postgres triggers (see supabase/schema.sql).
   ============================================================ */
'use strict';
(function () {
  const cfg = window.LUMO_CONFIG || {};
  const ready = !!(cfg.SUPABASE_URL && cfg.SUPABASE_ANON_KEY);

  async function insert(table, row) {
    if (!ready) { console.warn('[lumo] backend not configured — skipped insert into ' + table); return { ok: false, skipped: true }; }
    try {
      const r = await fetch(cfg.SUPABASE_URL + '/rest/v1/' + table, {
        method: 'POST',
        headers: {
          apikey: cfg.SUPABASE_ANON_KEY,
          Authorization: 'Bearer ' + cfg.SUPABASE_ANON_KEY,
          'Content-Type': 'application/json',
          Prefer: 'return=minimal'
        },
        body: JSON.stringify(row)
      });
      return { ok: r.ok, status: r.status };
    } catch (e) { console.warn('[lumo] insert failed', e); return { ok: false }; }
  }

  async function update(table, match, patch) {
    if (!ready) return { ok: false, skipped: true };
    try {
      const q = Object.entries(match).map(([k, v]) => k + '=eq.' + encodeURIComponent(v)).join('&');
      const r = await fetch(cfg.SUPABASE_URL + '/rest/v1/' + table + '?' + q, {
        method: 'PATCH',
        headers: {
          apikey: cfg.SUPABASE_ANON_KEY,
          Authorization: 'Bearer ' + cfg.SUPABASE_ANON_KEY,
          'Content-Type': 'application/json',
          Prefer: 'return=minimal'
        },
        body: JSON.stringify(patch)
      });
      return { ok: r.ok, status: r.status };
    } catch (e) { return { ok: false }; }
  }

  /* Save an in-progress run (exit-intent / save-run modal). */
  window.lumoSaveRun = function (state, email, estimate) {
    return insert('runs', {
      email,
      name: (state.answers && state.answers.name) || null,
      flow: state.flowKey || null,
      loan: estimate ? Math.round(estimate.loan) : null,
      rate: estimate ? +estimate.r.toFixed(3) : null,
      payment: estimate ? Math.round(estimate.p) : null,
      payload: state
    });
  };

  /* Save a locked scenario (the gate) as a lead. */
  window.lumoSaveLead = function (file) {
    const pick = (file.pricing && file.pricing.pick) || {};
    return insert('leads', {
      file_id: file.id,
      first_name: file.first,
      last_name: file.last || null,
      email: file.email,
      phone: file.phone || null,
      flow: file.flowKey,
      program: pick.name || null,
      loan: Math.round(file.pricing.loan || 0),
      rate_lo: pick.lo != null ? +pick.lo.toFixed(3) : null,
      rate_hi: pick.hi != null ? +pick.hi.toFixed(3) : null,
      status: file.status || 'locked',
      payload: file
    });
  };

  /* Progress a lead (verified, preapproved, lo_unlocked…). */
  window.lumoUpdateLead = function (fileId, patch) {
    return update('leads', { file_id: fileId }, patch);
  };
})();
