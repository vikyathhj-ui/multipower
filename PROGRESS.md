# PROGRESS

Single source of truth for status. Update this before every commit.
Spec: `docs/BRIEF.md`. Branch: `rework/pmu`. PRs target `master` (the repo's default branch).

**Current state (2026-11-01): Phase 3 IN PROGRESS (not at its gate).**
Resume point:
- Formal: properties 1-8 PROVEN (k-induction, `sby -f formal/pmu.sby prove`); property 9 PROVEN as
  per-state bounds (`live` task). The cover task was started earlier but not collected; rerun with
  `python3 scripts/run_formal.py` (it writes results/formal/summary.json). The RTL changed after the
  last proof (target() loop for Icarus, D-012 to write), so rerun everything.
- Simulation: tb/ (domain shells, env, coverage, 9 tests) all PASS with `--soak 200`; full 10^4 soak
  not yet run. Next: `.venv/bin/python scripts/mutate.py` (mutation check, written, not yet run),
  then the full run, coverage report, docs/VERIFICATION.md, DECISIONS D-012 (Icarus genvar/function
  bug) and the unexplained `unique case` bound observation, CI workflow, `make verify`, commit, PR.

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
- [x] PR for Phase 0 (opened together with Phase 1's, after the owner's spec review).

## Phase 1 — Spec
- [x] ARM IHI 0024E (APB) and IHI 0068D (LPI) read from Arm's documentation service; section and page
      numbers cited in SPEC (§2.1, §3.1, §3.3, §3.4, §4.1 of 0024E; §2.1.1–§2.1.4 and Table 2-1 of
      0068D). The PDFs are not committed.
- [x] `docs/SPEC.md`: domains, states, modes, sequences, delays and timeouts, inrush rule, wake-up,
      interfaces; 6 WaveDrom diagrams (`scripts/check_wavedrom.py` checks them).
- [x] `scripts/regmap.yaml` → `scripts/gen_regmap.py` → `docs/REGMAP.md`, `sw/pmu_regs.h`,
      `tb/regmap.py` (`--check` for staleness; the header compiles with gcc).
- [x] **Gate:** owner confirmed the spec (all 10 [decision] items, D-003). Commit, push, open PR.

## Phase 2 — RTL
- [x] `rtl/pmu_top.sv`, `apb_regs.sv`, `pd_ctrl.sv` (× `N_PD`), `qch_master.sv`, `inrush_arb.sv`,
      `wake_ctrl.sv`, `cells/icg_wrap.sv`, `cells/iso_wrap.sv`; plus `sync_ff.sv`, `rst_sync.sv` and the
      generated `pmu_regmap_pkg.sv`. Structure in `docs/MICROARCH.md`.
- [x] FSM encoding (D-005), reset strategy (D-006), synchronisers (D-007), cell wrappers (D-008),
      delay counting (D-010). No latches (Yosys check with the sky130 wrappers).
- [x] **Gate:** `make lint`: `verilator --lint-only -Wall` clean in 4 parameter configurations, with 3
      justified inline waivers (D-009); Yosys synth keeps 3 `dlclkp_1` + 9 `lpflow_inputiso0p_1`.

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
- The Phase 1 register-map outputs in PR #1 contain the YAML ON/OFF bug (D-011); the fix is in the
  Phase 2 commit.
- `lpflow` isolation cells are excluded by LibreLane's sky130 config. Whether a wrapper instance
  survives synthesis and PnR is to be checked in Phase 2/4 (BRIEF rule 6 if not).
