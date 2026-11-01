# UPF review — `upf/pmu_soc.upf` against the RTL

No open-source UPF checker exists, so `upf/pmu_soc.upf` is checked by hand. This table pairs every
strategy with the RTL signal or instance that implements it and the check that verifies the
behaviour. Reviewed on 2026-11-01 against `rtl/` and `tb/` at the Phase 3 commit.

## Domains and supplies

| UPF | Implemented by | Checked by | OK |
|---|---|---|---|
| `PD_AON` (scope, `ss_aon`) contains the PMU | `tb_top.u_pmu` (`rtl/pmu_top.sv`) | — (structure) | yes |
| `PD_CPU` = `g_dom[0].u_dom`, `PD_DSP` = `g_dom[1].u_dom`, `PD_PERI` = `g_dom[2].u_dom` | `tb/tb_top.sv` generate loop, `HAS_RET = 3'b011` | — (structure) | yes |
| Switched supplies `VDD_CPU/DSP/PERI` | the domain shell's `pwr` = both switch acks (`tb_top.sv`) | env pin-level power check | yes |
| Single voltage, no level shifters | all domains 1.8 V | — | yes (SPEC §11) |

## Power switches

| UPF | Implemented by | Checked by | OK |
|---|---|---|---|
| `sw_trickle_<pd>`: control `psw_trickle_en[d]`, ack `psw_trickle_ack[d]` | `pd_ctrl` steps U_TRK_ON, D_TRK_OFF | formal h6a; scoreboard templates `pu*`, `pd_*` | yes |
| `sw_main_<pd>`: control `psw_main_en[d]`, ack `psw_main_ack[d]` | `pd_ctrl` steps U_MAIN_ON, D_MAIN_OFF | formal h6b; scoreboard | yes |
| Staging: main after trickle on, main off before trickle off | state order in `pd_ctrl` (SPEC §4.1, §4.3) | formal property 4; scoreboard; mutant `trickle_first_off` caught | yes |
| One domain powering up at a time (not expressible in UPF) | `inrush_arb` | formal property 5; env inrush check; mutant `arb_no_hold` caught | yes |

## Isolation

| UPF | Implemented by | Checked by | OK |
|---|---|---|---|
| `iso_<pd>_c0`: shell register bus, clamp 0, signal `iso_en[d]` high, parent side, AON supply | `domain_shell.g_iso[*]` (`iso_wrap #(.CLAMP(0))`) on `regs_raw` | env: isolated bus = all 0, no X | see note 1 |
| `iso_<pd>_c1`: `rdy_n`, clamp 1 | `domain_shell.u_iso_rdy` (`iso_wrap #(.CLAMP(1))`) | env: isolated `rdy_n` = 1 | see note 1 |
| Q-Channel outputs (QACCEPTn/QDENY/QACTIVE) clamp 0 | `pmu_top.g_pd[d].u_iso_acc/deny/act` (`iso_wrap #(.CLAMP(0))`, sky130 `lpflow_inputiso0p_1` in synthesis) | formal h3; env Q-Channel checks | yes |
| Isolation before power-off, released last | `pd_ctrl` (iso step 4 down, step 8 up) | formal properties 1, 2; mutant `iso_release_early` caught | yes |

## Retention

| UPF | Implemented by | Checked by | OK |
|---|---|---|---|
| `ret_PD_CPU`, `ret_PD_DSP`: elements `rlive`, retention supply `ss_aon` | `domain_shell.rlive` + `shadow` (`g_ret`) | env: restored value = value at `ret_save` | yes |
| Save signal `ret_save[d]` high | `pd_ctrl` D_SAVE (only if `HAS_RET` and target RET) | formal property 3, h4c; mutant `no_ret_save` caught | yes |
| Restore signal `ret_restore[d]` high | `pd_ctrl` U_RESTORE (only if `RET_VALID`) | formal h4d; mutant `no_restore` caught | yes |
| No retention in `PD_PERI` | `HAS_RET[2] = 0` | formal h4e; coverage ignores PERI retention bins | yes |

## Power states

| UPF | Implemented by | Checked by | OK |
|---|---|---|---|
| Domain states ON / CLK_GATED / RET / OFF | `pd_ctrl` S_ON / S_CG / S_RET / S_OFF; `PD_STATE` register | formal h2/h6 (outputs per state); sim | yes |
| CLK_GATED is supply-ON | S_CG keeps both switches on (h6), `clk_en` = 0 | formal h2e/f, h6 | yes |
| System states RUN … SHUTDOWN = mode table | `pmu_top.target()` (SPEC §3.2); `MODE_STATUS` | `test_transition_matrix` (5×5) | yes |
| RET target also met by OFF | `pd_ctrl.at_tgt` | `expect_states()` in the tests | yes (note 2) |

## Notes
1. **Isolation placement in the model.** In the testbench the bus and `rdy_n` clamps are
   instantiated *inside* `domain_shell`, but modelled as always on: they are never corrupted, and
   their enable comes from the PMU. The UPF places them on the parent side with `ss_aon`, which is
   the real intent; a power-aware tool would insert them there. The Q-Channel clamps *are* on the
   AON side, inside `pmu_top`.
2. **States the UPF must allow.** SLEEP and DEEP_SLEEP allow OFF where the mode table says RET
   (SPEC §3.2, D-003.4). Without that, states the RTL really reaches would be listed as illegal.
3. **What UPF cannot say** and the RTL/verification covers instead:
   - the order of the steps (iso before save before reset before switch-off);
   - the delays and timeouts;
   - the inrush rule;
   - the Q-Channel handshake.

   These are proven by the formal properties.
4. **Not verified by any tool:** the UPF syntax itself, and whether a commercial flow would accept
   it. This review is manual.
