/* ============================================================
   LUMOLEND core — shared helpers, LoanFile persistence, demo data
   ============================================================ */
'use strict';
const $ = id => document.getElementById(id);
const money = n => '$' + Math.round(n).toLocaleString('en-US');
const moneyK = n => n >= 1e6 ? ('$' + (n / 1e6).toFixed(2).replace(/\.?0+$/, '') + 'M') : ('$' + Math.round(n / 1000) + 'K');
const pct = n => n.toFixed(3).replace(/0+$/, '').replace(/\.$/, '') + '%';
function pmt(rate, principal, months = 360) { const r = rate / 100 / 12; return principal * r / (1 - Math.pow(1 + r, -months)); }
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

const FLOW_LABELS = {
  home: 'Home purchase', refi: 'Refinance', dscr: 'DSCR rental',
  str: 'Short-term rental', bridge: 'Fix & flip bridge', heloc: 'Home equity'
};
const CREDIT_LABELS = { '760': '760+', '720': '720–759', '680': '680–719', '640': '640–679', '600': 'Below 640' };

/* ---------- LoanFile persistence ---------- */
function decodeHashFile() {
  const m = location.hash.match(/#f=(.+)/);
  if (!m) return null;
  try { return JSON.parse(decodeURIComponent(escape(atob(decodeURIComponent(m[1]))))); }
  catch (e) { return null; }
}
function encodeFileHash(f) {
  return '#f=' + encodeURIComponent(btoa(unescape(encodeURIComponent(JSON.stringify(f)))));
}
function loadLoanFile() {
  const h = decodeHashFile();
  if (h) { try { localStorage.setItem('lumolend_file', JSON.stringify(h)); } catch (_) {} return h; }
  try { const s = localStorage.getItem('lumolend_file'); if (s) return JSON.parse(s); } catch (_) {}
  return null;
}
function saveLoanFile(f) {
  try {
    localStorage.setItem('lumolend_file', JSON.stringify(f));
    const pl = JSON.parse(localStorage.getItem('lumolend_pipeline') || '[]');
    const i = pl.findIndex(x => x.id === f.id);
    if (i >= 0) pl[i] = f; else pl.unshift(f);
    localStorage.setItem('lumolend_pipeline', JSON.stringify(pl.slice(0, 20)));
  } catch (_) {}
}
/* ---------- confirmation-adjusted pricing ----------
   Each block the borrower confirms removes uncertainty:
   the indicative band narrows toward its floor.       */
function certainty(f) {
  let c = 35;
  if (f.verifications.identity) c += 25;
  if (f.verifications.address) c += 20;
  if (f.verifications.scenario) c += 20;
  return c;
}
function firmedBand(f) {
  const p = f.pricing.pick || { lo: f.pricing.rate, hi: f.pricing.rate + 0.75 };
  const span = p.hi - p.lo;
  const keep = 1 - (certainty(f) - 35) / 65 * 0.78;   // fully verified keeps ~22% of span
  const lo = p.lo + span * (1 - keep) * 0.35;          // floor creeps up slightly (honesty)
  return { lo, hi: lo + span * keep };
}
function statusLabel(f) {
  return { priced: 'PRICED', submitted: 'SUBMITTED', confirmed: 'IN REVIEW', desk: 'AT THE DESK' }[f.status] || 'PRICED';
}
