# PROGRESS

Single source of truth for status. Update this before every commit.
Spec: `docs/BRIEF.md`. Branch: `rework/pmu`. PRs target `master` (the repo's default branch).

**Current state (2026-11-01): Phase 3 gate passed with ONE OPEN ITEM (owner's choice: commit now).**
PR for Phase 3 open; waiting for the owner. Open item: the formal cover RUN→SHUTDOWN→RUN is unreached
up to step 77 (run stopped by a 2.5 h limit); options: split into two covers or a longer run.
Phase 4 (UPF, break-even analysis, LibreLane on the PMU) next.

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
- [x] `formal/pmu_props.sv`: properties 1–8 PROVEN (k-induction); property 9 PROVEN as per-state bounds
      (`live` task), end-to-end bound from `scripts/liveness_bound.py`.
- [~] Covers: 17 of 18 reached; RUN→SHUTDOWN→RUN unreached up to step 77 (OPEN ITEM, see above).
- [x] Counterexamples saved to `results/formal_cex/`; "Bugs found by formal" F-001..F-005 in DECISIONS.
- [x] cocotb: APB driver/monitor, Q-channel device model, switch model with fault injection, domain
      shells (X corruption + retention), isolation clamps, cycle-timed sequence scoreboard.
- [x] Tests: 5×5 transitions, deny at every step (14 cases), timeout at every wait (21 cases), wake
      race, simultaneous wakes, illegal APB, reset while on (48), soak 10⁴ requests: 10/10 PASS.
- [x] Functional coverage 100% of 137 bins (impossible bins listed with reasons).
- [x] Mutation: control + 11 mutants, all caught (`results/mutation.json`).
- [x] `make verify` targets, `results/verify_summary.json` ("PASS with open items"), CI workflow.
- [x] **Gate:** all tests pass, coverage met, all properties PROVEN; one cover open. Commit, PR.

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
