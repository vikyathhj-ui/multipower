# PROGRESS

Single source of truth for status. Update this before every commit.
Spec: `docs/BRIEF.md`. Branch: `rework/pmu`. PRs target `master` (the repo's default branch).

**Current state (2026-11-01): Phase 1 spec written, WAITING FOR THE OWNER'S REVIEW. No RTL until confirmed.**

## Phase 0 — Setup and audit
- [x] Environment check (`scripts/env_check.sh` → `results/env_check.txt`): all tools found. The repo
      venv got `cocotb-coverage==2.0`. ICG `dlclkp_{1,2,4}` and `lpflow_inputiso*` present in the
      liberty; LibreLane excludes `lpflow_*` from synth and PnR.
- [x] `docs/BRIEF.md` (verbatim), `CLAUDE.md`, `PROGRESS.md`, `.gitattributes`, `.gitignore`, `LICENSE`.
- [x] Layout created; old code moved to `legacy/` with `git mv`.
- [x] `docs/AUDIT.md`, backed by `scripts/legacy_probe.sh` → `results/legacy_probe.txt`: timer
      sequencing CONFIRMED, tautological checks CONFIRMED (14 of 24), hard-coded 4.98 mW CONFIRMED;
      plus a demonstrated inrush violation.
- [x] Commit and push `rework/pmu`.
- [ ] PR for Phase 0 (opened together with Phase 1's, after the owner's spec review).

## Phase 1 — Spec
- [x] ARM IHI 0024E (APB) and IHI 0068D (LPI) read from Arm's documentation service; section and page
      numbers cited in SPEC (§2.1, §3.1, §3.3, §3.4, §4.1 of 0024E; §2.1.1–§2.1.4 and Table 2-1 of
      0068D). The PDFs are not committed.
- [x] `docs/SPEC.md`: domains, states, modes, sequences, delays and timeouts, inrush rule, wake-up,
      interfaces; 6 WaveDrom diagrams (`scripts/check_wavedrom.py` checks them).
- [x] `scripts/regmap.yaml` → `scripts/gen_regmap.py` → `docs/REGMAP.md`, `sw/pmu_regs.h`,
      `tb/regmap.py` (`--check` for staleness; the header compiles with gcc).
- [ ] **Gate:** owner reviews and confirms the spec before any RTL. Commit, push, open PR.

## Phase 2 — RTL
- [ ] `rtl/pmu_top.sv`, `apb_regs.sv`, `pd_ctrl.sv` (× `N_PD`), `qch_master.sv`, `inrush_arb.sv`,
      `wake_ctrl.sv`, `cells/icg_wrap.sv`, `cells/iso_wrap.sv`.
- [ ] FSM encoding justified, no latches, reset strategy documented (DECISIONS).
- [ ] **Gate:** `verilator --lint-only -Wall` clean. Commit.

## Phase 3 — Formal, then simulation
- [ ] `formal/pmu_props.sv`: properties 1–9 PROVEN, covers reached.
- [ ] Counterexamples saved to `results/formal_cex/`; "Bugs found by formal" in DECISIONS.
- [ ] cocotb: APB driver/monitor, Q-channel model, switch model with fault injection, domain shells
      (corruption + retention), isolation clamps, scoreboard.
- [ ] Tests: 5×5 transitions, deny at every step, timeout at every wait, wake-during-power-down race,
      simultaneous wakes, illegal APB, soak ≥ 10⁴ random requests.
- [ ] Functional coverage at 100% of defined bins (or each gap justified).
- [ ] `make verify` → `results/verify_summary.json`; CI for lint, reduced sim and formal.
- [ ] **Gate:** all pass, coverage met. Commit, open PR.

## Phase 4 — UPF, power analysis, physical
- [ ] `upf/pmu_soc.upf` with the honesty header; `docs/UPF_REVIEW.md`.
- [ ] `analysis/breakeven.py` (named parameters), plots, `docs/POWER_ANALYSIS.md`.
      PD_CPU load: P1 ALU netlist (owner to confirm the path).
- [ ] LibreLane on the PMU (AON): area, timing at all corners, power → `summary.json`. Out-of-scope
      items stated.
- [ ] **Gate:** done. Commit, open PR.

## Phase 5 — Docs and close
- [ ] README (pitch, block diagram, mode table, sequence diagram, generated results table,
      Reproduce, Limitations, AI assistance).
- [ ] Final LEARNING and INTERVIEW (30+ questions, required topics).
- [ ] `results/resume_bullets.md` from `summary.json`.
- [ ] `make all`.
- [ ] Final PR; then ask about renaming the repo to `soc-pmu-sequencer`.

## Open issues
- `lpflow` isolation cells are excluded by LibreLane's sky130 config. Whether a wrapper instance
  survives synthesis and PnR is to be checked in Phase 2/4 (BRIEF rule 6 if not).
