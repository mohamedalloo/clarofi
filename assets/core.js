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
const CREDIT_MID = { '760': 782, '720': 738, '680': 701, '640': 662, '600': 618 };

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
function loadPipeline() {
  try { return JSON.parse(localStorage.getItem('lumolend_pipeline') || '[]'); } catch (_) { return []; }
}

/* ---------- verification-adjusted pricing ----------
   Each completed verification removes uncertainty:
   the indicative band narrows toward its floor.      */
function certainty(f) {
  let c = 35;
  if (f.verifications.credit) c += 25;
  if (f.verifications.assets) c += 20;
  if (f.verifications.income) c += 20;
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
  return { priced: 'PRICED', verified: 'VERIFIED', preapproved: 'PRE-APPROVED', desk: 'AT THE DESK' }[f.status] || 'PRICED';
}

/* ---------- demo files (seed the desk pipeline) ---------- */
function demoFiles() {
  const now = Date.now();
  return [
    {
      id: 'LL-DEMO01', created: new Date(now - 26 * 60000).toISOString(),
      first: 'Priya', last: 'Raman', email: 'priya@example.com', phone: '(415) 555-0182',
      flowKey: 'home', answers: { intent: 'home', stage: 'offers', price: 985000, downPct: 20, income: 'bank', vet: 'no', credit: '740', name: 'Priya' },
      pricing: {
        loan: 788000, rate: 7.06, payment: 5271,
        pick: { name: 'Bank statement 30-yr', lo: 7.0, hi: 7.625 },
        cards: [
          { name: 'Bank statement 30-yr', desc: 'Deposits qualify you — not tax returns', lo: 7.0, hi: 7.625, rec: true },
          { name: 'Bank statement 40-yr IO', desc: 'Lower payment, 10-yr interest-only', lo: 7.25, hi: 7.875, rec: false },
          { name: 'Conventional (if returns work)', desc: 'Worth testing your filed income', lo: 6.25, hi: 6.625, rec: false }],
        verdict: 'Routes to bank-statement lending — deposits qualify, not the Schedule C.'
      },
      verifications: {
        credit: { score: 738, at: new Date(now - 20 * 60000).toISOString() },
        assets: { verified: 262000, accounts: 2, at: new Date(now - 18 * 60000).toISOString() },
        income: null
      },
      status: 'verified'
    },
    {
      id: 'LL-DEMO02', created: new Date(now - 3 * 3600000).toISOString(),
      first: 'Marcus', last: 'Webb', email: 'marcus@example.com', phone: '(602) 555-0147',
      flowKey: 'bridge', answers: { intent: 'bridge', buy: 410000, rehab: 95000, arv: 685000, exp: '5', credit: '720', name: 'Marcus' },
      pricing: {
        loan: 429250, rate: 10.31, payment: 3689,
        pick: { name: '12-mo interest-only', lo: 9.81, hi: 10.56 },
        cards: [
          { name: '12-mo interest-only', desc: 'The standard flip structure', lo: 9.81, hi: 10.56, rec: true },
          { name: '18-mo interest-only', desc: 'Room for a slower exit', lo: 10.06, hi: 10.81, rec: false },
          { name: 'Bridge-to-DSCR', desc: 'Auto-refi into a rental loan at exit', lo: 9.94, hi: 10.69, rec: false }],
        verdict: 'All-in basis $505K vs $685K ARV = $180K gross (36%). Healthy spread.'
      },
      verifications: {
        credit: { score: 741, at: new Date(now - 2.6 * 3600000).toISOString() },
        assets: { verified: 214000, accounts: 3, at: new Date(now - 2.5 * 3600000).toISOString() },
        income: { method: 'Experience-based (operator)', at: new Date(now - 2.4 * 3600000).toISOString() }
      },
      status: 'preapproved'
    },
    {
      id: 'LL-DEMO03', created: new Date(now - 26 * 3600000).toISOString(),
      first: 'Dana', last: 'Okafor', email: 'dana@example.com', phone: '(303) 555-0121',
      flowKey: 'dscr', answers: { intent: 'dscr', pr: 'purchase', value: 465000, rent: 3350, ltv: 70, credit: '760', name: 'Dana' },
      pricing: {
        loan: 325500, rate: 7.0, payment: 2166,
        pick: { name: '5-yr prepay', lo: 7.0, hi: 7.5 },
        cards: [
          { name: '5-yr prepay', desc: 'Best rate — built to hold', lo: 7.0, hi: 7.5, rec: true },
          { name: '3-yr prepay', desc: 'Balanced flexibility', lo: 7.25, hi: 7.75, rec: false },
          { name: 'No prepay', desc: 'Full freedom to exit', lo: 7.5, hi: 8.0, rec: false }],
        verdict: 'Coverage runs about 1.31× — strong file.'
      },
      verifications: { credit: { score: 785, at: new Date(now - 25 * 3600000).toISOString() }, assets: null, income: null },
      status: 'priced'
    }
  ];
}
