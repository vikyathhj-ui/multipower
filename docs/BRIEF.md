# P2 — `soc-pmu-sequencer`

**Title:** Formally Verified Multi-Domain Power Management Unit (APB, Q-Channel handshake, UPF power intent).

Reworks `multipower`. P6 (`lp-rv32-mcu`) reuses this PMU as an APB peripheral, so keep the APB interface standard and the register map generated from YAML. Target roles are digital/SoC front-end design and low-power design (NXP, TI, Infineon). NXP India postings list low-power techniques and UPF.

## Part A — Design specification (read this yourself)

### A1. Why this stands out
Almost no student project shows *power intent*. This one shows the full industry picture:
- the correct power-down and power-up ordering of clock gating, isolation, retention, reset and power switches;
- a standard Arm-style low-power handshake, programmed over APB;
- staged power switches to limit inrush current;
- a UPF power-intent file;
- power-aware simulation that corrupts state when a domain is off;
- formally proven safety properties;
- an engineering analysis of when entering each low-power mode actually saves energy (break-even residency).

### A2. System spec
- **Domains:**
  - `AON`: always on; contains the PMU itself.
  - `PD_CPU`: switchable, **with retention**.
  - `PD_DSP`: switchable, **with retention**.
  - `PD_PERI`: switchable, **no retention**.

  Make the switchable-domain count a parameter (`N_PD = 3`).
- **Domain states:** `ON` → `CLK_GATED` → `RET` (retention: logic off, retention flops alive) → `OFF`. Error state: `FAULT`.
- **System modes**, programmed in the `MODE_REQ` register:

  | Mode | PD_CPU | PD_DSP | PD_PERI |
  |---|---|---|---|
  | RUN | ON | ON | ON |
  | IDLE | CLK_GATED | CLK_GATED | ON |
  | SLEEP | RET | RET | CLK_GATED |
  | DEEP_SLEEP | RET | OFF | OFF |
  | SHUTDOWN | OFF | OFF | OFF |
- **Power-down sequence, per domain:**
  1. Q-channel quiesce request.
  2. Wait for accept, or abort on deny.
  3. `clk_en`=0 (drives an ICG cell).
  4. `iso_en`=1.
  5. `ret_save` (if the domain has retention and target = RET).
  6. `rst_n`=0.
  7. Power switches off: main switch first, then the trickle switch.
  8. Wait `psw_ack`=0, with a timeout.
- **Power-up sequence:**
  1. Trickle switch on.
  2. Wait ack.
  3. Main switch on.
  4. Wait ack (staged to limit inrush).
  5. `ret_restore` (if the domain has retention).
  6. `rst_n`=1.
  7. `clk_en`=1.
  8. `iso_en`=0.
  9. Q-channel exit.
- **Programmable delays:** every "wait" step has a delay register in clock cycles and a timeout register. A timeout leads to `FAULT`, sets a status bit and raises an interrupt.
- **Inrush rule:** at most one domain may be in a power-up switching phase at any time. Requests are serialised by a fixed-priority arbiter (CPU > DSP > PERI), and the priority order is documented.
- **Wake-up:** a wake-up source (`wake_irq[7:0]`, maskable per bit) or the AON wake timer (32-bit compare) brings the system to the mode in `WAKE_MODE`.
- **Interfaces:**
  - **APB3 slave** (Arm IHI 0024): `PCLK`, `PRESETn`, `PSEL`, `PENABLE`, `PWRITE`, `PADDR[11:0]`, `PWDATA`, `PRDATA`, `PREADY`, `PSLVERR`. Undefined address → `PSLVERR`=1.
  - **Per-domain low-power handshake** modelled on Arm AMBA LPI **Q-Channel** (Arm IHI 0068): `QREQn`, `QACCEPTn`, `QDENY`, `QACTIVE`. Check the signal semantics and the legal state sequence against the spec, and cite the section numbers in `docs/SPEC.md`.
  - **Per domain:** `clk_en`, `iso_en`, `ret_save`, `ret_restore`, `rst_n`, `psw_trickle_en`, `psw_main_en`, `psw_trickle_ack`, `psw_main_ack`.
  - `irq` output, plus a `pmu_state` debug bus.
- **Register map** (`docs/REGMAP.md`, also generated as a C header and as a Python dict for the testbench): `MODE_REQ`, `MODE_STATUS`, `WAKE_MODE`, `WAKE_MASK`, `WAKE_TIMER_CMP`, `DLY_*`, `TMO_*`, `IRQ_STATUS` (write-1-to-clear), `IRQ_EN`, `FAULT_INFO`, `ID/VERSION`.

### A3. Verification spec
- **cocotb testbench**, Icarus is fine:
  - APB driver and monitor.
  - A Q-channel domain-controller model with configurable accept/deny/latency behaviour.
  - A power-switch model with configurable ack delay, plus fault injection: no ack, so the timeout path is exercised.
  - A scoreboard checking every sequence order against `docs/SPEC.md`.
- **Power-aware simulation, without a commercial tool:** each switchable domain has a behavioural "domain shell" with N normal registers and M retention registers.
  - **When power is off:** normal registers become X (Icarus 4-state), or random under a 2-state simulator; retention registers keep their value only if `ret_save` was done.
  - **Isolation cells:** behavioural clamp-0/clamp-1 models on every domain output.
  - **Checks:** no X ever reaches AON while `iso_en`=1; retention registers restore correctly; non-retention registers come out of reset; no output change is observed during isolation.
- **Tests:** every mode-to-mode transition (5×5 matrix), deny at every step, timeout at every wait step, wake-up during a power-down sequence (a race), simultaneous wake requests, APB illegal access, and random long-run soak tests (≥ 10⁴ random mode requests with random latencies).
- **Functional coverage:** the transition matrix, per-domain state × event, deny/timeout location, and the register-access matrix. Target 100% of defined bins.
- **Formal (SymbiYosys, immediate assertions + `$past`), safety properties to prove:**
  1. `!pwr_good[d] -> iso_en[d] && !clk_en[d] && !rst_n[d]` (`pwr_good` = both switch acks high).
  2. `!iso_en[d] -> pwr_good[d] && rst_n[d]`, and `$fell(iso_en[d]) -> clk_en[d]`, so isolation is released last on power-up. Note that `CLK_GATED` is powered and unisolated with `clk_en`=0, which is why this is not a plain implication on `clk_en`.
  3. `ret_save[d]` is asserted only when `iso_en[d] && !clk_en[d]`.
  4. `psw_main_en[d]` rises only when `psw_trickle_ack[d]` has been high for at least `DLY_TRICKLE` cycles.
  5. **Inrush:** at most one domain is in a power-up switching phase at any time.
  6. Q-channel legal sequencing (from the spec's state machine).
  7. APB: `PREADY`/`PSLVERR` only in the access phase; registers change only on a valid write.
  8. Every FSM stays in legal states.
  9. **Bounded liveness:** assuming acks arrive within K cycles, every request reaches its target or `FAULT` within a bound you derive and state.

  **Covers:** every domain state reached, a full RUN→SHUTDOWN→RUN cycle, a FAULT from timeout, and a deny abort.
- **Lint:** `verilator --lint-only -Wall` clean.

### A4. Power intent and analysis
- **`upf/pmu_soc.upf`** (IEEE 1801): supply sets, power domains, power switches (trickle + main), isolation strategies (clamp values per port), retention strategies, and the power state table matching the mode table.
  - The header must say: **"No open-source UPF checker exists; this file documents intent and is reviewed manually against the RTL; see docs/UPF_REVIEW.md."**
  - `docs/UPF_REVIEW.md` is a manual cross-check table: every UPF strategy against the RTL signal that implements it.
- **Clock gating:** use the sky130 ICG cell (`sky130_fd_sc_hd__dlclkp_*`) via a wrapper with a behavioural model for simulation. Check the exact cell name in the liberty file.
- **Isolation:** if sky130 `lpflow` isolation cells exist in the installed liberty (e.g. `sky130_fd_sc_hd__lpflow_inputiso*`), instantiate them through a wrapper. Otherwise keep behavioural clamps and document that.
- **Break-even residency analysis** (`analysis/breakeven.py`, `docs/POWER_ANALYSIS.md`):
  - **Leakage per domain:** use the post-synthesis cell list of the P1 ALU (if available) as the load for `PD_CPU`, summing cell leakage from the sky130 liberty at the TT/SS/FF corners. Otherwise use a clearly labelled representative netlist.
  - **Transition energy:** the energy to enter and exit each mode, from documented assumptions (switch capacitance, retention save/restore energy, PMU active power from OpenSTA). Every assumption is a named parameter.
  - **Outputs:** the break-even residency time for IDLE, SLEEP, DEEP_SLEEP and SHUTDOWN; a plot of energy saved vs residency; a recommended mode-selection policy.
- **Physical:** LibreLane on the PMU (AON logic) for area, timing at all corners and power. **State plainly that the multi-domain power-gated layout is out of scope for the open flow.**

### A5. Deliverables
- `docs/SPEC.md`, with sequence diagrams (WaveDrom) for every transition.
- `docs/REGMAP.md`, `docs/MICROARCH.md`, `docs/VERIFICATION.md` (test plan → tests → coverage → proofs), `docs/POWER_ANALYSIS.md`, `docs/UPF_REVIEW.md`.
- `docs/DECISIONS.md`, `docs/LEARNING.md`, `docs/INTERVIEW.md`.
- `results/summary.json`, the only source of numbers.
- `make all`; CI for lint, sim and formal.

### A6. Done when
- All tests pass, coverage is 100% (or each gap justified), and all properties are PROVEN.
- The PMU closes timing post-route at every corner.
- The break-even analysis is complete.
- The old `multipower` claims are retired: `docs/AUDIT.md` lists what was wrong (timer-based "handshakes", tautological testbench checks, hard-coded 4.98 mW).
- You can answer `INTERVIEW.md` without notes.

---

## Part B — Prompt for Claude Code

**How to use this:** paste this **entire file** (Part A and Part B) into Claude Code as one message. Part A is the binding spec. Claude saves the whole file as `docs/BRIEF.md` so later sessions can re-read it.

---

You are working in my existing GitHub repo `multipower` (owner `vikyathhj-ui`). Turn it into `soc-pmu-sequencer`: a multi-domain SoC power-management controller with APB registers, Q-Channel-style handshakes, staged power switches, UPF power intent, power-aware simulation, formally verified sequencing, and a break-even residency analysis. Part A of this message is the binding specification. I am a final-year ECE student applying for VLSI design roles; correctness and honesty matter more than speed.

### Non-negotiable rules
1. **Never fabricate or hand-type a result.** Every number comes from a script that reads a tool output, stored in `results/summary.json` with its source path. All analysis assumptions are named parameters, listed in the doc that uses them.
2. **Never rewrite or backdate git history.** No force-push to `main`. Work on branch `rework/pmu`.
3. **Commit protocol:**
   - Commit after each gate in PROGRESS.md, using Conventional Commits.
   - The body covers what changed, why, and the verification command and result.
   - Keep the default `Co-Authored-By: Claude` trailer.
   - Push after each commit. Open a PR to `main` at the end of each phase with `gh pr create`; the description covers changes, evidence and open issues.
   - **Do not merge. I merge.**
4. **Ask me before:** renaming the repo, changing visibility, archiving or deleting repos, installing system packages, or acting outside this repo.
5. Whenever you cite the Arm APB or LPI Q-Channel specs, give the section numbers. If you cannot access a spec, say so; do not invent protocol details. Mark anything from memory as "to verify against IHI 0068".
6. If something in the spec is infeasible with the installed tools (e.g. a missing lpflow cell), stop, explain, and propose the closest honest alternative.
7. Keep `PROGRESS.md` current. Keep `docs/DECISIONS.md`, `docs/LEARNING.md` and `docs/INTERVIEW.md` updated, with 30+ questions answered using this project's numbers. The questions must cover:
   - why isolation comes before power-off;
   - why isolation is released last;
   - retention vs state save to memory;
   - inrush and staged switches;
   - Q-Channel accept vs deny;
   - why ICG cells rather than AND gates;
   - break-even residency;
   - what UPF describes that RTL doesn't;
   - immediate vs concurrent assertions;
   - bounded vs unbounded proofs.

### Phase 0 — Setup and audit (one commit)
- **Environment check:** `iverilog`, `verilator`, `yosys`, `sby` + a solver, `python3` + `cocotb` + `cocotb-coverage`, `librelane`/`openlane`, `openroad`, `sta`, the sky130A PDK (`PDK_ROOT`), and the liberty file path for `sky130_fd_sc_hd`.
  - Print a found/missing table. If anything is missing, stop and give me install commands; don't run sudo.
  - Search the liberty for `dlclkp` and `lpflow` cells and report what exists.
- **Save the brief and set up the repo:** save this whole message verbatim as `docs/BRIEF.md`. Create `CLAUDE.md` (rules, layout, "binding spec is docs/BRIEF.md"), `PROGRESS.md` (all gates as checkboxes), `.gitattributes` (`* text=auto eol=lf`), `.gitignore`, and `LICENSE` (MIT).
- **Audit:** write `docs/AUDIT.md` covering every flaw in the existing RTL/testbench, with file and line. Confirm or refute: timer-based sequencing with no real handshake, tautological checks, hard-coded 4.98 mW.
- **Layout:**
  ```
  rtl/  tb/  formal/  upf/  analysis/  flow/  scripts/  results/  docs/  legacy/  .github/workflows/
  ```
  Move the old code to `legacy/`.

### Phase 1 — Spec
- Write `docs/SPEC.md` and `docs/REGMAP.md` from Part A, including WaveDrom diagrams for every power-down and power-up sequence.
- Generate `sw/pmu_regs.h` and `tb/regmap.py` from one source (`scripts/regmap.yaml` → generator script).

Gate: I review the spec. Stop and ask me to confirm before starting the RTL.

### Phase 2 — RTL
- `rtl/pmu_top.sv`, `rtl/apb_regs.sv`, `rtl/pd_ctrl.sv` (per-domain FSM, instantiated `N_PD` times), `rtl/qch_master.sv`, `rtl/inrush_arb.sv`, `rtl/wake_ctrl.sv` (mask + timer), `rtl/cells/icg_wrap.sv`, `rtl/cells/iso_wrap.sv`.
- Requirements: one-hot or binary-encoded FSMs (justify the choice in DECISIONS.md); no latches; a reset strategy documented.

Gate: lint clean. Commit.

### Phase 3 — Formal first, then simulation
- `formal/pmu_props.sv`, bound to the RTL. Prove properties 1–9 from A3 and run the covers. Fix the RTL until everything is PROVEN.
- **Every counterexample you find is a bug story:** save its trace to `results/formal_cex/` and write it up in DECISIONS.md under "Bugs found by formal".
- **cocotb environment:** APB driver/monitor, Q-channel domain model, power-switch model with fault injection, domain shells with corruption plus retention, behavioural isolation clamps, and a scoreboard.
- Tests as in A3, plus the coverage report.
- `make verify` writes `results/verify_summary.json`.
- CI workflow for lint, a reduced sim and formal.

Gate: all pass, coverage target met. Commit, then open a PR.

### Phase 4 — UPF, power analysis, physical
- `upf/pmu_soc.upf` with the honesty header; `docs/UPF_REVIEW.md` cross-check table.
- `analysis/breakeven.py`, with every assumption a named parameter; plots; `docs/POWER_ANALYSIS.md`.
  - Use the P1 ALU netlist if I tell you its path. Otherwise ask me, and fall back to a labelled representative netlist.
- LibreLane on the PMU: report area, timing at all corners and power into `summary.json`.
- State the out-of-scope items plainly.

Gate: done. Commit.

### Phase 5 — Docs and close
- **README:**
  - pitch;
  - block diagram;
  - the mode table;
  - one sequence diagram;
  - results table auto-generated from `summary.json`;
  - "Reproduce";
  - "Limitations": no silicon; UPF not tool-checked; behavioural isolation/retention models where applicable;
  - "AI assistance": "Developed with Claude Code; all results reproduced by Vikyath J with `make all`."
- Finalise LEARNING and INTERVIEW.
- `results/resume_bullets.md`: 3 bullets using only `summary.json` numbers.
- Open the final PR. Then ask me whether to rename the repo to `soc-pmu-sequencer`.

Start with Phase 0, in plan mode, and show me the plan before editing files.
