# Audit of the original `multipower` project

The original design (commit `5139347`, now in `legacy/`) claimed: *"3-domain power design - 25
metrics verified, 34 iso cells, 33 level shifters, 75.9% leakage reduction, 24/24 tests pass."* This
audit checks each claim against the code. Every finding cites file:line and the output of
`scripts/legacy_probe.sh` → `results/legacy_probe.txt` (sections L1–L5). The probe compiles and runs
the original testbench unchanged in Icarus, plus an audit probe (`legacy/tb_probe.v`, new, clearly
separate).

## Verdict on the brief's three claims

| Claim to check (BRIEF Phase 0) | Verdict | Evidence |
|---|---|---|
| Timer-based sequencing, no real handshake | **CONFIRMED** | L3, L5 |
| Tautological testbench checks | **CONFIRMED**: 14 of 24 checks cannot fail, or compare constants | L1, L2 and the table below |
| Hard-coded 4.98 mW | **CONFIRMED**, together with 1.20 mW and the derived "75.9%" | L1, L2 |

## A. Sequencing (`legacy/src/power_manager_v3.v`)

1. **No handshake of any kind.** The module's only inputs are `clk`, `rst`, `enable_dsp` and
   `enable_mem` (lines 2–5, L3). No power-switch acknowledge, no domain quiesce/accept, no timeout.
   The controller cannot know whether a domain actually powered up or down.
2. **Every step is a fixed counter value.** Power-up: `power_gate_n` at `dsp_cnt == 4` (line 67),
   restore at `== 8` (69), isolation release at `== 12` (71). Power-down: save at `== 2` (92), gate off
   at `== 6` (94), done at `== 10` (98). MEM repeats them (136–166). L5 measures power-gate on 6
   cycles, restore 10 and iso release 14 after each request, identical every time, whatever the
   supply does.
3. **The inrush protection does not work.** MEM may start waking when
   `dsp_stagger_done || !enable_dsp` (line 128). DSP's WAKE state never checks `enable_dsp`, so a
   request withdrawn mid-wake leaves DSP switching while MEM starts.
   - The probe (L5, P2) does exactly this: **12 cycles with both domains in WAKE**, and
     `inrush_safe = 1` in all 12.
   - `inrush_safe` is set on MEM's OFF→WAKE edge (line 131) and cleared only by reset (line 119), so
     it reports nothing about the current state.
4. **Incomplete power-down sequence.** There is no clock gating, no reset assertion before power-off,
   and no reset release on power-up. Isolation is asserted in the same cycle as the state change
   (lines 85–86), which is the right order, but the rest of the ordering the brief requires is
   missing.
5. **The "metrics" are constants.** `dsp_wakeup_latency <= dsp_cnt` is captured at `dsp_cnt == 12`,
   so it is always 12 (line 74). The testbench then "verifies" `wake_latency=12cy`
   (`legacy/tb_power_v3.v:130`).

## B. Power domains, isolation, level shifters, retention

6. **The "level shifters" are wires.** `level_shifter_HL` and `level_shifter_bus32` are
   `assign data_out = data_in` (`legacy/src/iso_cells.v:31`, `:38`, L4). The design has a single
   supply: there is no UPF, and `legacy/config.json` is a single-voltage sky130 `hd` flow. The
   "33 level shifters" are 33 bits of wire (a 32-bit bus plus 1 bit; `top_power_v3.v:126`, `:131`).
   The 1.8 V / 1.2 V labels exist only in comments.
7. **"34 iso cells" is a literal.** The testbench sets `iso_cells_required=34; iso_cells_inserted=34;`
   (`tb_power_v3.v:89`) and then checks they are equal (`:171`). The design has isolation logic on 33
   bits at the top (`iso_bus32` + `iso_and`, `top_power_v3.v:106`, `:112`).
8. **Isolation placed inside the switchable domain.** `mem_domain_v3.v:39–41` clamps `mem_out`,
   `buffer_full` and `fill_level` with logic that sits *inside* MEM. When MEM is powered off, that
   clamp is unpowered too, so it cannot isolate anything. Isolation cells must be powered from the
   always-on side.
9. **No power-off behaviour is modelled.** The domain registers keep their values while
   `power_gate_n = 0`, with no corruption to X. So "retention" and "corruption-free" can never fail.
   Only `data_valid` is gated with `power_gate_n` (`top_power_v3.v:94`, `:144`).
10. **`retention_ff` is never used.** The module exists (`iso_cells.v:41`) but has 0 instances (L4).
    "Retention" is a shadow copy, written by `save` inside the switchable domain itself
    (`dsp_domain_v3.v:55–60`), and would lose power with the domain.
11. **The retention check is a tautology.** `restore_success <= (ret_result == pre_sleep_result)`
    (`dsp_domain_v3.v:62`), where both registers are written from `result_reg` by the same `save`
    (lines 58–59, L2). It never compares the restored working state with what was saved.
12. **The "retained register" counts are constants.** `retained_reg_count <= 8'd36`
    (`dsp_domain_v3.v:44`) and `<= 8'd8` (`mem_domain_v3.v:44–45`); the testbench checks those
    constants (`tb_power_v3.v:194`, `:197`).

## C. Power numbers

13. **4.98 mW and 1.20 mW are typed in.** `tb_power_v3.v:226–227`:
    `power_all_on = 4.98; // mW (from our earlier measurement)` and `power_gated = 1.20`. No tool
    output is read.
14. **"75.9% leakage reduction"** is `(4.98 − 1.20) / 4.98` computed from those two literals
    (`:228`, printed in L1). It is also mislabelled: an all-on vs gated *total* power figure, if real,
    would not be leakage.
15. **"Wake-up energy"** = the literal 4.98 mW × the constant 12 cycles × 10 ns (`:229`).

## D. The testbench: what the 24 PASS lines check

`legacy/tb_power_v3.v` has 24 `check_metric` calls, all PASS (L1). The commit says "25 metrics" and
"24/24 tests". The `name` argument is 128 bits, so labels print truncated to 16 characters (L1).

| Line | Check | Class |
|---|---|---|
| 105–109 | reset values: no domain active, both OFF | real (trivial) |
| 120 | `dsp_state==WAKING` right after `wait(dsp_state == 2'b01)` (118) | **tautological** |
| 121 | `iso_en=1 during wake` | real |
| 128 | `dsp_active` right after `wait(dsp_active == 1)` (123) | **tautological** |
| 129 | `dsp_state==ON` | real |
| 130 | `wake_latency==12`, a timer constant (item 5) | **constant** |
| 138, 139 | `iso_en=0`, `power_gate_n=1` when ON | real |
| 142 | `successful_transitions>=1`, the testbench's own counter, incremented at 141 | **tautological** |
| 152 | `inrush_safe`, a sticky flag (item 3) | **vacuous**: 1 even during a violation |
| 171 | iso cells: literal 34 == literal 34 | **literal** |
| 183 | level shifters: literal 33 == literal 33 | **literal** |
| 194, 197 | retained regs == RTL constants 36, 8 (item 12) | **constant** |
| 208 | `dsp_state==SLEEP` right after `wait(dsp_state == 2'b11)` (206) | **tautological** |
| 215 | `restore_success`, the self-comparison of item 11 | **vacuous** |
| 217 | `corruption_free>=1`, the testbench's own counter, incremented at 216 | **tautological** |
| 236 | `leakage_reduction>50%`, from the literals of item 13 | **literal** |
| 243 | `inrush_safe` again | **vacuous** |
| 253 | `dsp_transitions>=2` | real |

- **Real checks: 10** (5 of them reset values). Tautological, literal, constant or vacuous: **14**.
- **Missing entirely:** the MAC result is printed but never checked (`:163`); MEM contents are never
  checked; there are no power-down ordering checks. The line "Sequence: ISO→SAVE→GATE verified" is a
  `$display` with no check behind it (`:140`).

## E. Repository hygiene
16. **Build outputs were committed:** `power_v3.vcd` and the compiled `power_v3_sim` (now in
    `legacy/`, kept only as history).
17. **No README, no license, no spec, no CI.**

## What the rework does instead (BRIEF Part A)
- Real handshakes: Q-Channel quiesce/accept/deny per domain and power-switch acknowledges, each with
  a programmable delay and timeout leading to `FAULT`.
- The full power-down/power-up ordering (clock gate, isolation, retention, reset, staged trickle →
  main switches), with an inrush arbiter proven formally to allow one domain at a time.
- Power-aware simulation: domain shells corrupt state to X when off; isolation clamps sit on the
  always-on side; retention is checked against what was saved.
- Every number comes from a tool output, stored in `results/summary.json` with its source.
