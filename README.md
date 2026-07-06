# LumoLend

**AI finds it. A human funds it.**

A three-surface mortgage experience: an AI pricer that feels like a game, a verification engine that turns pricing into proof, and a command deck that hands the best human MLO everything they need to close the loan on the fastest possible path.

## The three surfaces

### 1. `index.html` — The Pricer
A conversational pricing journey (purchase, refi, DSCR, STR, fix & flip, HELOC). Every answer moves a live HUD — loan, rate estimate, monthly payment — in real time. Ends at indicative pricing across three structures and a gate that locks the scenario into a **LoanFile**.

- Tron-grid aesthetic, circuit-board progress, section-complete interstitials
- Flow-specific logic: DSCR coverage math, bridge LTC caps, HELOC DTI + CLTV ceilings, VA routing, bank-statement income detection
- Exit-intent save-run capture
- On lock: builds a structured LoanFile and hands off to pre-approval

### 2. `preapprove.html` — The Scenario Review
Three one-tap confirmations (identity & contact, property address, scenario snapshot), each with a live terminal-style scan of the borrower's own inputs. The centerpiece: a **review-readiness meter** and a **rate band that visibly narrows** as the file firms up. At 100% the scenario is queued for loan-officer review. No letters are auto-generated — pre-approvals are issued by the loan officer after review.

### 3. The MLO Command Deck (unpublished)
`desk.html` — the internal per-file view (fastest path to clear-to-close, risk radar, lender routing, call script, run replay) — is currently unpublished while the desk isn't in use. It lives in git history (`git show c5e7f86:desk.html`) and can be restored when needed.

## Architecture

```
lumolend/
├── index.html          # Pricer — self-contained (single-file artifact)
├── preapprove.html     # Scenario review
└── assets/
    ├── theme.css       # Shared design tokens & primitives
    └── core.js         # Helpers, LoanFile persistence, pricing firm-up, demo data
```

**State handoff.** A `LoanFile` JSON travels between surfaces two ways at once: URL hash (`#f=<base64>`) for portability, `localStorage` (`lumolend_file` + `lumolend_pipeline`) for persistence. Works from `file://` with zero backend.

**Pricing firm-up model.** `firmedBand()` in `core.js`: each completed verification removes a share of the indicative spread; a fully verified file keeps ~22% of the original band. The floor creeps up slightly as the band tightens — honesty over theater.

## Run it

No build, no server. Open `index.html` in a browser. Or:

```bash
npx serve .
```

Run a full journey → submit the scenario for review → confirm identity, address and scenario on the review runway.

## Status / disclaimers

Live at [lumolend.com](https://lumolend.com), operated by Honest Casa LLC (NMLS #1566096 · CA DRE #02022356). Nothing is auto-verified or auto-approved — every scenario is reviewed by a loan officer, and pre-approval letters are issued only after review. Rates are illustrative indicative ranges, not offers or commitments to lend. Equal Housing Lender.

## Roadmap

- Real integrations: soft-pull bureau, Plaid-style asset/VOE, pricing engine (OB/Polly)
- LoanFile → LOS handoff (Encompass/BytePro) from the desk
- Borrower/MLO shared timeline with live status
- A/B harness on journey copy & step order
