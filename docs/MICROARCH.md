# Micro-architecture

How `rtl/` implements `docs/SPEC.md`. Design choices are in `docs/DECISIONS.md` (D-0xx).

## Module tree

| Module | File | Role |
|---|---|---|
| `pmu_top` | `rtl/pmu_top.sv` | Top level: registers, wake, arbiter, `N_PD` domain slices, system status |
| `rst_sync` | `rtl/rst_sync.sv` | `PRESETn` asynchronous assert, synchronous release (D-006) |
| `apb_regs` | `rtl/apb_regs.sv` | APB3 completer and every register in `docs/REGMAP.md` |
| `pmu_regmap_pkg` | `rtl/pmu_regmap_pkg.sv` | Addresses, resets, encodings; generated from `scripts/regmap.yaml` |
| `wake_ctrl` | `rtl/wake_ctrl.sv` | `wake_irq` rising-edge detect with mask; 32-bit one-shot wake timer |
| `inrush_arb` | `rtl/inrush_arb.sv` | Fixed-priority, non-preemptive grant for the power-up switching phase |
| `pd_ctrl` | `rtl/pd_ctrl.sv` | Per-domain sequencer (22-state binary FSM, D-005), one per domain |
| `qch_master` | `rtl/qch_master.sv` | Q-Channel controller: the QREQn register and the IHI 0068D controller rules |
| `sync_ff` | `rtl/sync_ff.sv` | `SYNC_STAGES` synchroniser for every asynchronous input (D-007) |
| `icg_wrap` | `rtl/cells/icg_wrap.sv` | Domain clock gate: `sky130_fd_sc_hd__dlclkp_1` or a behavioural model (D-008) |
| `iso_wrap` | `rtl/cells/iso_wrap.sv` | Isolation clamp: `sky130_fd_sc_hd__lpflow_inputiso{0,1}p_1` or a behavioural model |

## Per-domain slice (`pmu_top.g_pd[d]`)

```
QACCEPTn/QDENY/QACTIVE ─► iso_wrap (clamp 0, iso_en[d]) ─► sync_ff ─► qch_master ◄─► pd_ctrl
psw_trickle_ack / psw_main_ack ──────────────────────────► sync_ff ─────────────────► pd_ctrl
pd_ctrl ─► clk_en, iso_en, ret_save, ret_restore, rst_n, psw_trickle_en, psw_main_en
clk_en[d] ─► icg_wrap(PCLK) ─► pd_clk[d]
pd_ctrl.inrush_req ─► inrush_arb ─► inrush_gnt ─► pd_ctrl
```

## `pd_ctrl` states

| Code | State | SPEC step | Outputs changed on entry |
|---|---|---|---|
| 0 | S_ON | stable | — |
| 1 | S_CG | stable | — |
| 2 | S_RET | stable | — |
| 3 | S_OFF | stable (reset state) | — |
| 4 | S_FAULT | §4.6 | power-switch fault: safe off configuration; Q fault: none |
| 5 | D_QWAIT | 4.1 steps 1–2 | `stop_req` (QREQn falls through `qch_master`) |
| 6 | D_DENY | 4.5 | (QREQn rises in `qch_master`) |
| 7 | D_CLK | 4.1 step 3 | `clk_en`=0 |
| 8 | D_ISO | step 4 | `iso_en`=1 |
| 9 | D_SAVE | step 5 | `ret_save`=1 |
| 10 | D_RST | step 6 | `rst_n`=0 |
| 11 | D_MAIN_OFF | step 7a | `psw_main_en`=0 |
| 12 | D_TRK_OFF | step 7b/8 | `psw_trickle_en`=0 |
| 13 | U_ARB | 4.3 step 0 | `inrush_req`=1 |
| 14 | U_TRK_ON | steps 1–2 | `psw_trickle_en`=1 |
| 15 | U_MAIN_ON | steps 3–4 | `psw_main_en`=1 |
| 16 | U_RESTORE | step 5 | `ret_restore`=1 |
| 17 | U_RST | step 6 | `rst_n`=1 |
| 18 | U_CLK | step 7 | `clk_en`=1 |
| 19 | U_ISO | step 8 | `iso_en`=0 |
| 20 | U_QEXIT | step 9 | `exit_req` (QREQn rises in `qch_master`) |
| 21 | C_CLK | 4.2 CG-up | `clk_en`=1 |

Every output is a flop that changes only on a state transition, so each output's ordering is set by
the state order above. The formal properties check that ordering (Phase 3).

## Debug bus `pmu_state` (width 7·N_PD + 1)

| Bits | Content |
|---|---|
| `[7d+4:7d]` | `pd_ctrl` state code of domain d (table above) |
| `[7d+5]` | inrush grant of domain d |
| `[7d+6]` | QACTIVE of domain d, synchronised (observed only; D-003.7) |
| `[7·N_PD]` | system busy (`MODE_STATUS.BUSY`) |

## System status
- `all_at_tgt` = every domain stable and satisfying its target (SPEC §3.2).
- `MODE_STATUS.MODE` follows `MODE_REQ` whenever `all_at_tgt`.
- `BUSY` = some domain is armed and not at its target. `MISMATCH` = not busy and not all at target,
  which happens after a deny.
- `IRQ_STATUS.DONE` fires once per request (or boot), when every domain is at its target.
