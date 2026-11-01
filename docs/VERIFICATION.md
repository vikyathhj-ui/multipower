# Verification

Test plan → tests → coverage → proofs for `pmu_top` (docs/BRIEF.md A3). Every number here comes
from a result file, named next to it; `make verify` regenerates them all and writes the roll-up in
`results/verify_summary.json`.

## 1. Strategy
- **Formal first** (SymbiYosys + yices, `formal/`): the safety properties are proven for *all*
  reachable states (k-induction), not sampled.
- **Simulation** (cocotb on Icarus, `tb/`): the behaviour that formal does not express easily is
  simulated against behavioural models of everything around the PMU.
  - *What it adds:* the full mode transitions, retention contents, the APB register map, wake-up,
    fault recovery, and long random runs.
  - *Power-aware models:* domain shells corrupt to X when unpowered (Icarus 4-state).
- **Mutation** (`scripts/mutate.py`): deliberate bugs are inserted to show that the checks can fail.

## 2. Test plan

| Requirement (BRIEF A3) | Where it is checked |
|---|---|
| Every mode-to-mode transition (5×5) | `test_transition_matrix`; coverage point `transition` |
| Deny at every step | `test_deny_every_step`: every quiescence request of every domain in every transition that makes it quiesce (`DENY_CASES`); coverage `deny_loc` |
| Timeout at every wait step | `test_timeout_every_wait`: all 7 wait steps × 3 domains, including FAULT_INFO, irq, safe outputs and recovery; coverage `fault_loc` |
| Wake-up during a power-down (race) | `test_wake_race`: a wake every 3 cycles across power-down and power-up sequences |
| Simultaneous wake requests | `test_wake_sources`: four `wake_irq` bits and the timer compare in the same cycle; masking; one-shot timer |
| APB illegal access | `test_apb_errors`: every unmapped word address, every RO register, illegal mode values; nothing changes |
| Register map | `test_reset_and_registers`: reset values, read-back, W1C; coverage `reg_access` |
| Random long run, ≥ 10⁴ requests | `test_soak`: random modes, latencies, delays, denies, requests mid-transition |
| No X reaches AON while isolated; no output change during isolation | env check on every cycle: isolated outputs must equal the clamp values exactly |
| Retention registers restore correctly; non-retention registers come out of reset | env check at every isolation release: retention = value saved at `ret_save`, normal = reset value |
| Sequence order per SPEC §4 | env scoreboard: every completed sequence is compared with its template (a suffix after a FAULT) |
| Properties 1–9 | `formal/pmu_props.sv` (section 5) |

## 3. Testbench (`tb/`)
- **`domain_shell.sv`:** one per domain.
  - 4 normal registers, reset to `A0+16·d+i`, which become X on power loss.
  - 2 retention registers: a live copy plus an AON shadow; restore overrides reset (D-003.6).
  - Outputs to AON through behavioural isolation clamps, both clamp-0 and clamp-1.
- **`pmu_env.py`:**
  - **APB requester and protocol monitor.**
  - **Q-Channel device model:** follows the IHI 0068D §2.1.2 device rules and acts only when
    powered, out of reset and clocked; random latency; deny with a set probability; fault
    injection: silent at a chosen point.
  - **Power-switch model:** random ack delay; fault injection: an ack never arrives.
  - **Checkers:** isolation, X, retention and reset values; Q-Channel controller rules and the
    reset-in-Q_STOPPED rule; inrush (property 5); trickle settle time (property 4); APB phase rules.
  - **Sequence scoreboard.**
- **`pmu_coverage.py`:** cocotb-coverage points (section 4).
- **`test_pmu.py`:** the 9 tests.

## 4. Results
- **Simulation:** 9/9 tests pass with the 10⁴-request soak (`results/sim/icarus.xml`; per-test
  counts in `results/verify_summary.json`).
- **Functional coverage:** 100% of the defined bins (`results/coverage/icarus.json`). Bins the
  specification makes impossible are left out and listed in that file with the reason (`ignored`).
  They are all consequences of PD_PERI having no retention: no RET states, no save or restore, and
  no RET target in any mode.

| Point | Bins |
|---|---|
| `transition` | (from mode, to mode), 5×5 |
| `dom_seq` | (domain, sequence kind): power-down to RET/OFF, clock gating down/up, CG→RET/OFF, power-up with/without restore, deny, RET→OFF, fault, fault recovery |
| `deny_loc` | (domain, target of the denied request) |
| `fault_loc` | (domain, FAULT_INFO.STEP), 3×7 |
| `reg_access` | (register, read/write, ok/err), plus unmapped |
| `power_up` | (domain, restored or from reset) |

## 5. Formal (`formal/pmu.sby`, `formal/pmu_props.sv`, `scripts/run_formal.py`)
**Environment assumptions** (each a fact about the outside world, stated in the property file):
- **SW:** switch acks change only after their enable.
- **QD:** the device follows the IHI 0068D §2.1.2 device rules and drives LOW in reset.
- **R:** reset in the first cycle.

| Task | What | Method | Result file |
|---|---|---|---|
| `prove` | properties 1–8, plus helper invariants h1–h7 | k-induction, depth 24 | `results/formal/summary.json` |
| `live` | property 9 pieces: per-state time bounds, leaving an off-target stable state, arbiter grant | k-induction, configuration fixed at reset values | same |
| `cover` | every domain state reached, a deny, a FAULT, RUN→SHUTDOWN→RUN | BMC cover, depth 80 | same |

**Open item: the RUN→SHUTDOWN→RUN cover.** 17 of the 18 covers are reached (`cover` task). The
full RUN→SHUTDOWN→RUN cycle (`c_run_sd_run`) was **not reached**: the solver checked every trace up to
77 steps and was then stopped during step 78 by the 2.5-hour time limit of the run, with steps taking
over 15 minutes each (`results/formal/cover_logfile.txt`). Boot alone needs about 26 steps at the
reset delay values, and the three power-ups are serialised by the arbiter, so the cycle is deep;
this is an estimate, not a measurement. The cycle is exercised in simulation (`test_transition_matrix`
and `test_soak`). Options recorded for later: split it into two half-depth covers, or a longer run.

**Property 9, end to end.** The `live` task proves each piece. `scripts/liveness_bound.py` adds them
along the longest path one request can take: finish a power-down, wait for the arbiter while both
other domains switch on, power up, clock-gate. The resulting bound in cycles, and its assumptions
(reset configuration, no deny, fault or new request meanwhile), are in
`results/formal/liveness_bound.json`. Without the reset configuration the bound is the same
formula with the programmed `DLY_*`/`TMO_*` values.

**Why the bound uses timeouts, not "acks within K cycles":** the brief allows assuming acks arrive
within K cycles. Every wait here is cut off by its timeout anyway, so the bound holds *without* that
assumption: a missing ack ends in FAULT within the timeout. With K < TMO, each wait term can be
replaced by K + `SYNC_STAGES` + 1 for a tighter bound.

**Counterexamples found** (`results/formal_cex/`, written up in DECISIONS "Bugs found by formal"):
- **F-001:** a real RTL bug, the stale switch ack (fixed).
- **F-002:** a gap in the environment assumption.
- **F-003:** a bug in the property itself.
- **F-004:** the induction invariants needed.
- **F-005:** a weak P7, found by mutation.

## 6. Mutation (`scripts/mutate.py` → `results/mutation.json`)
- Each mutant is one deliberate bug in a copy of `rtl/`. The cocotb suite must fail, and for
  safety-related mutants the k-induction proof must fail too.
- An unmodified control copy runs first and must pass both, so a broken harness cannot pass for a
  good result. The first harness run was invalid for that reason; see DECISIONS.

## 7. Lint
`make lint` (`results/lint_summary.txt`): Verilator `-Wall` in four parameter configurations, and a
Yosys synthesis with the sky130 cell wrappers that must contain no latches.

## 8. Limits
- **Behavioural models:** the domain, device and switch models are behavioural. Real isolation
  cells, retention flops and power switches are not simulated at transistor or UPF level, because no
  open-source power-aware simulator exists (BRIEF A3).
- **Liveness:** proven for the reset configuration; other configurations follow from the formula.
- **Icarus only:** simulation runs on Icarus 4-state, which X corruption needs.
