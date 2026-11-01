# Decisions

Every design and method decision, with its reason and evidence. Numbered in order; never renumbered.

## D-001 — Repo-local Python venv for cocotb-coverage
- **Context:** the image has cocotb 2.0.1 but not cocotb-coverage (`results/env_check.txt`).
- **Choice:** `.venv` created with `--system-site-packages`, with `cocotb-coverage==2.0` installed
  into it. This is not a system install (BRIEF rule 4). `.venv` is git-ignored.

## D-002 — Arm specification issues used
- **Choice:** ARM IHI 0024E (APB, 2023) and ARM IHI 0068D (LPI, 2021), both Non-Confidential, from
  Arm's documentation service. Section and page numbers in `docs/SPEC.md` refer to these issues.
- The PDFs are not committed (Arm copyright). The text was extracted locally to read the sections.

## D-003 — Specification gap decisions (owner confirmed 2026-11-01)
The brief leaves these behaviours open. Each one is in `docs/SPEC.md` (marked [decision]), and the
owner confirmed all ten at the Phase 1 gate.

1. **Requests while busy** (SPEC §6): a domain completes its current sequence, then moves to the
   newest target; it is never reversed mid-sequence (deny and FAULT are the exceptions). This keeps
   every sequence atomic, so the safety properties hold in every interleaving. The cost: a wake during
   a power-down waits for the power-down to finish.
2. **Deny** (SPEC §4.5): the domain stays ON, `IRQ_STATUS.DENY` is set, and the domain does not retry
   until `MODE_REQ` is written again or a wake event occurs. `MODE_STATUS.MISMATCH` shows it. This
   avoids a request/deny loop against a busy device.
3. **FAULT** (SPEC §4.6):
   - A power-switch timeout forces the safe off configuration.
   - A Q-Channel timeout holds the outputs as they are, because IHI 0068D §2.1.2 forbids raising QREQn
     before the handshake completes and forbids asserting reset outside Q_STOPPED.
   - Clearing `IRQ_STATUS.FAULT` recovers: a PSW fault goes to OFF, a Q fault resumes its wait.
4. **OFF satisfies a RET target** (SPEC §3.2).
5. **Power-up always passes through ON.** CLK_GATED from RET/OFF means up to ON, then clock-gate.
   Isolation is released only with the clock running (property 2).
6. **`ret_restore` comes before `rst_n` release**, as the brief orders it. A retention flop's restore
   overrides its reset.
7. **Software-led QACTIVE policy:** QACTIVE is observed but does not start transitions. Wake-up comes
   from rising edges of unmasked `wake_irq` and the one-shot wake timer.
8. **Reset and boot:** every domain is OFF after reset. `MODE_REQ` resets to RUN, so the PMU boots all
   domains in priority order.
9. **Erroring APB writes never change state**, which is stricter than IHI 0024E §3.4 allows.
10. **PR target branch:** `master`, the repo's default. Renaming it is the owner's call.

## D-004 — Register map from one YAML source
- **Choice:** `scripts/regmap.yaml` → `scripts/gen_regmap.py` → `docs/REGMAP.md`, `sw/pmu_regs.h`,
  `tb/regmap.py`. `--check` fails if any output is stale. The RTL register block is checked against
  the same file in Phase 2/3.
- **Notes:**
  - Delays and timeouts are global, shared by all domains: 6 `DLY_*` and 2 `TMO_*` registers, 16 bits
    each.
  - A programmed delay of 0 is treated as 1; a timeout of 0 means 65536.
  - `WAKE_MASK` bit = 1 means *masked*; reset is all masked.
  - `WAKE_CTRL` is an addition to the brief's list, needed to start the timer.
  - `PD_STATE` is an addition, for software visibility of each domain.

## D-005 — FSM encoding: binary
- **Context:** BRIEF Phase 2 asks for one-hot or binary FSMs, with the choice justified.
- **Choice:** binary-encoded `typedef enum` for `pd_ctrl` (22 states, 5 bits). `qch_master` has a
  single QREQn register. The arbiter grant is a registered one-hot vector.
- **Why:**
  - **Area and power:** 5 flops per domain instead of 22. The PMU is always on, so its leakage
    counts in every low-power mode.
  - **Timing:** not critical. The next-state logic is shallow and the PMU clock is slow compared
    with sky130 gate delays (checked post-route in Phase 4).
  - **Formal:** property 8 ("legal states") becomes `st <= C_CLK` on 5 bits, which is easy to state
    and prove. One-hot would need `$onehot(st)`.
  - **Safety:** the unused codes 22–31 go to FAULT through the `default` branch.

## D-006 — Reset strategy
- **One reset input,** `PRESETn`, active low. `rst_sync` asserts reset asynchronously, so every flop
  clears at once even without a clock, and releases it synchronously through two flops, so no flop
  sees reset removal close to a clock edge.
- **All PMU flops** use the synchronised `rstn` as an asynchronous active-low reset.
- **Reset state is the safe state:** every domain OFF, isolated and in reset, with switches off and
  QREQn low (Q_STOPPED). Controller and device are reset together, which IHI 0068D §2.1.2 allows.
- **Domain resets** (`rst_n[d]`) are outputs of `pd_ctrl`, asserted and released only by the
  sequences in SPEC §4.

## D-007 — Synchronisers on every input from another domain
- **Choice:** QACCEPTn, QDENY, QACTIVE (after isolation), both switch acks and `wake_irq` each pass
  through `sync_ff` (`SYNC_STAGES` = 2 by default; lint also checks 3).
- **Why:** IHI 0068D §2.1.1 assumes all Q-Channel signals are asynchronous. Power-switch acks come
  from analogue switch sensing.
- **Cost:** `SYNC_STAGES` cycles of latency on every handshake. This is included in the
  liveness bound (Phase 3).
- **Why sampling the synchronised values is safe:** QREQn is decided from synchronised values that
  are up to `SYNC_STAGES` cycles old. The device rules (IHI 0068D §2.1.2) only let the device change
  QACCEPTn/QDENY in response to a QREQn change, so the true values cannot change while QREQn is
  steady. Property 6 checks this formally, against the real pins.

## D-008 — sky130 cell wrappers
- **ICG:** `rtl/cells/icg_wrap.sv` instantiates `sky130_fd_sc_hd__dlclkp_1` when `PMU_SKY130_CELLS`
  is defined (liberty: `GCLK = CLK & M0`, with the enable latched while CLK is low). Otherwise it uses
  a behavioural latch-and-AND model.
- **Isolation:** `rtl/cells/iso_wrap.sv` uses `lpflow_inputiso0p_1` (X = !SLEEP & A) for clamp 0 and
  `lpflow_inputiso1p_1` (X = A | SLEEP) for clamp 1. The functions were read from the tt liberty.
- **Where the cells are:** inside `pmu_top`, on the PMU's own inputs from the switchable domains
  (QACCEPTn, QDENY, QACTIVE; 3 per domain), and on the gated domain clocks.
- **Evidence:** `scripts/lint.sh` synthesises with the wrappers enabled; the result keeps
  3 × `dlclkp_1` and 9 × `lpflow_inputiso0p_1` and has no latches (`results/lint_summary.txt`).
- **Still open:** LibreLane's sky130 config excludes `lpflow_*` from synthesis and PnR. Whether
  instantiated cells survive the flow is checked in Phase 4 (BRIEF rule 6).

## D-009 — Lint waivers (three, each inline with its reason)
1. `apb_regs.paddr[1:0]` is unused: registers are word-aligned (SPEC §2.1).
2. `pmu_top.in_pu_switch` is used only by the formal inrush property (property 5).
3. `rst_sync`'s SYNCASYNCNET: a reset synchroniser is by design a flop that is reset asynchronously
   and drives a reset.

The generated `pmu_regmap_pkg.sv` also waives UNUSEDPARAM. It is a constant table, and the RTL uses
only part of it.

## D-010 — Delay and timeout counting
- **Holds:** one 17-bit counter per domain counts cycles since the step began. A hold step ends when
  count + 1 ≥ `DLY_*` (0 is treated as 1).
- **Waits:** a wait step faults when count + 1 ≥ `TMO_*` while its acknowledge is still missing
  (0 means 65536).
- **Steps with a settling hold** (trickle on, main on) also count consecutive acknowledge-high cycles.
  If the ack drops, that count restarts, but the timeout keeps running from the step's start. This is
  the window property 4 reasons about.
- **Configuration changes take effect at once,** because the comparisons use the live register
  values, even mid-step. Property 4 is stated against the value in force when `psw_main_en` rises.

## D-011 — Bug in the Phase 1 register-map generator (found in Phase 2)
- **Symptom:** `rtl/pmu_regmap_pkg.sv`, `sw/pmu_regs.h` and `docs/REGMAP.md` named two states
  `PD_STATE_True` and `PD_STATE_False`.
- **Cause:** PyYAML follows YAML 1.1, which reads the bare keys `ON` and `OFF` in `regmap.yaml` as
  booleans.
- **Fix:** the keys are quoted, and `gen_regmap.py` now fails if any enum key is not a string, so
  this cannot recur.
- **Found by:** linting the generated SystemVerilog package, whose warnings listed the odd names. The
  committed Phase 1 outputs had the bug; they are regenerated in the Phase 2 commit.

## D-012 — Icarus workaround: per-domain targets computed in a loop
- **Symptom:** Icarus 14.0-dev rejected `pmu_top`'s domain `generate` loop with "A reference to a net
  or variable (`d`) is not allowed in a constant expression" on every later use of the genvar.
  Verilator and Yosys accepted the same code.
- **Isolated** (`sim_build/ivltest/`): the trigger is a function call that takes the genvar as an
  argument inside a port connection, `.tgt(target(mode_req, d))`. Removing that one call makes
  the rest of the loop elaborate.
- **Fix:** the targets are computed in an `always_comb` loop into `tgt[N_PD]`, and the port connects
  `tgt[d]`. Logic is unchanged; lint and the formal proofs were rerun after the change.
- **Not kept:** two earlier attempts (local output wires, a renamed genvar) were based on a wrong
  diagnosis and were reverted.

## D-013 — Formal: per-state bounds written as plain implications
- The first version of property 9 selected each state's bound through a `unique case` mux inside
  the bound property module. Its induction trace showed the bound as 4 in a state that maps to
  0xFFFF. I did not reduce this to a minimal case, so the cause (tool or my code) is **unexplained**.
- The property was rewritten as one implication per state group, which is also easier to read; it
  proves. Recorded so the observation is not lost.

## D-014 — Representative load for the break-even analysis (owner's choice)
- **Context:** BRIEF A4 suggests the P1 ALU's post-synthesis cell list as PD_CPU's leakage load, or
  "a clearly labelled representative netlist". The owner chose the representative netlist
  (2026-11-01).
- **Choice:** the only open design in the container is LibreLane's example `spm` (serial-parallel
  multiplier).
  - It is synthesised to `sky130_fd_sc_hd` (yosys + abc, `results/power/rep_cells.json`).
  - Its cell mix gives the average leakage per cell, read from the liberty at each corner.
  - Domain sizes, flop fraction, clock-tree factor and switched capacitance are named assumptions
    (`analysis/breakeven.py` `PARAMS`).
- **Limit:** `spm` is one-third flops, which is not CPU-like. The flop fraction for clock power is
  therefore a separate parameter (0.15), not the `spm` value. Downloading a CPU core was not done:
  it would be acting outside this repo (BRIEF rule 4).

## D-015 — sky130 low-power cells survive LibreLane (BRIEF rule 6 check resolved)
- **Question:** LibreLane's sky130 configuration lists `sky130_fd_sc_hd__lpflow_*` as excluded
  from synthesis and PnR. Would the isolation cells instantiated in `iso_wrap` survive?
- **Result:** yes. The synthesised netlist of the PMU run (`flow/runs/pmu_T20`) keeps all 9
  `lpflow_inputiso0p_1` and all 3 `dlclkp_1`, and they are placed. The exclusion stops the tools
  from *choosing* those cells (mapping, resizing); it does not remove cells the RTL instantiates.
- **Consequence:** no fallback to behavioural clamps is needed in the PMU layout.

## D-016 — Exclude delay cells from place-and-route repair (PMU closes at 20 ns)
- **Symptom:** the first PMU layout at 20 ns (`flow/runs/pmu_T20`, metrics kept in
  `results/flow/T20_with_delay_cells_metrics.json`) failed setup at the three `ss` corners. Worst
  slack was −1.081 ns at `max_ss_100C_1v60`; TT and FF had about 4.7–5 ns of slack.
- **Cause:** the single failing path, a configuration register to domain 0's `ret_valid` through a
  counter compare, had **34 `clkdlybuf4s*` delay cells** on it. OpenROAD's repair used them as
  fanout buffers, because LibreLane's sky130 configuration excludes them from synthesis but not
  from PnR. This is the same effect found in the P1 STA report; there it was documented but not
  tested.
- **Choice:** `EXTRA_EXCLUDED_CELLS: ["sky130_fd_sc_hd__clkdlybuf*", "sky130_fd_sc_hd__dlygate*"]`
  in `flow/config.json`.
- **Result** (`flow/runs/pmu_T20_nodly`, `results/summary.json`):
  - worst setup slack +2.924 ns at `max_ss_100C_1v60` (fmax 58.56 MHz there);
  - **all 9 corners close**; worst hold slack 0.107 ns;
  - cell area 33,732.4 µm², against 35,646.7 µm²;
  - Magic/KLayout DRC, LVS and antenna all 0;
  - the 9 `lpflow_inputiso0p_1` and 3 `dlclkp_1` cells are kept.
- **Also:** `OPENROAD_THREADS: 4`. LibreLane passed `-threads None` when it was unset (it uses
  `str(None)`), and OpenROAD fell back to one thread.

---

## Bugs found by formal

Every counterexample is kept in `results/formal_cex/`: the VCD trace, plus a `.txt` table of its key
signals made by `scripts/cex_table.py`.

### F-001 — Stale power-switch acknowledge through the synchroniser (RTL bug, fixed)
- **Property:** P1, `!pwr_good → iso_en && !clk_en && !rst_n`. Basecase failure at step 8, domain 0.
  Trace: `cex01_p1_stale_switch_ack`.
- **What happened:**
  1. The switch acks were already high when the PMU came out of reset (the switches were still on,
     e.g. after a PMU-only reset). Both enables were 0, so the switches turned off and the real acks
     fell (step 5).
  2. The boot power-up began at step 6. The *synchronised* acks still showed 1 from before.
  3. The PMU took that as "trickle on" and "main on", and released the domain's reset at step 8,
     while the real supply was off.
- **Root cause:** an acknowledge was trusted as soon as its step began, but for `SYNC_STAGES` cycles
  the synchroniser can still hold a value sampled *before* the enable changed.
- **Fix** (`rtl/pd_ctrl.sv`, `settled`): in the four switch steps, an ack is used only once the step
  has lasted `SYNC_STAGES` cycles. From then on the synchronised value is a pin sample taken after the
  enable changed, and the switch cannot reverse while its enable is held (assumption SW).
- **Cost:** `SYNC_STAGES` extra cycles per switch step.
- **Lesson:** a synchroniser delays information. Any decision on a synchronised handshake must
  allow for answers that predate the request.

### F-002 — Device assumption did not cover the reset-release cycle (formal environment, fixed)
- **Property:** P6b, QREQn may rise only from 00 or 11. Basecase failure at step 17.
  Trace: `cex02_p6b_env_device_rule_gap`.
- **What happened:** the modelled device raised QACCEPTn in the same cycle it left reset, with QREQn
  LOW. IHI 0068D §2.1.2 forbids this. My device-rule assumption was enabled only from the cycle
  *after* reset release, so it allowed it.
- **Fix** (`formal/pmu_props.sv`): the device rules apply in every cycle the device is out of reset.
- **Not an RTL bug:** the PMU behaved correctly, because it saw the isolated (clamped 0) value.

### F-003 — Overflow in my own P4 monitor (property bug, fixed)
- **Symptom:** a P4 induction failure where the trickle ack had been high for the whole trace.
- **Cause:** the monitor `trk_hi` saturates at 17'h1FFFF, and the assertion added 1 in 17 bits, which
  wrapped to 0.
- **Fix:** compare in 18 bits.
- **Lesson:** check the checker's arithmetic too.

### F-004 — Induction needed invariants (not bugs)
After F-001–F-003 the base case passed to depth 24, but k-induction failed: it starts from
*arbitrary* states, including unreachable ones such as "U_MAIN_ON with the trickle enable off". Each
failure was resolved by stating a true invariant, which is then proven along with the properties.
- **h1:** powered states have both enables, both acks and every synchroniser stage high.
- **h1e/f:** the trickle switch is firmly on during the main-switch steps.
- **h2:** per-state values of `iso_en`, `rst_n` and `clk_en` (the table in MICROARCH).
- **h3:** Q_STOPPED from the accept onwards.
- **h4:** the retention pulses belong only to their states, and there are no retention states
  without `HAS_RET`.
- **h5:** `stop_req` and `exit_req` belong only to their wait states.
- **h6:** per-state switch enables.
- **h7:** inrush request and grant.
- **h4a/h4b:** the P4 hold counter never exceeds the real ack's high time.

With these, properties 1–8 are **proven unbounded** (k-induction, depth 24, about 12 s).

### F-005 — P7 trusted the design's own write decode (property weakness, found by mutation)
- **Found by:** the mutant `err_write_takes` (an erroring APB write still updates a register) still
  passed the proof.
- **Cause:** P7 defined "valid write" with the design's internal `we`. The mutant changed `we`, so the
  property agreed with the bug.
- **Fix:** P7 computes a valid write from the APB pins and the generated register map (access phase,
  write, the register's own address, legal mode value), independently of the RTL decode.
- **Lesson:** a property must not reuse the logic it is checking.

### Mutation harness: a first run that proved nothing (fixed)
- **What happened:** the first `scripts/mutate.py` run reported every mutant "caught". In fact the
  simulation never started in any mutant copy. The copy filter `pmu_cover*`, meant for SymbiYosys
  task folders, also skipped `tb/pmu_coverage.py`, and the import error counted as a failure.
- **Noticed because:** every simulation's first error was the same start-up message at 0 ns.
- **Fix:**
  - The copy filter skips only directories inside `formal/`.
  - An unmodified **control** copy must pass both the suite and the proof first.
  - A mutant counts as caught only if all tests ran and at least one failed on a check; a crash is
    reported as ERROR.
- **Lesson:** a mutation score needs a control run, or it can measure a broken harness.
