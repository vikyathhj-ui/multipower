# PMU functional specification

Binding requirements are in `docs/BRIEF.md` Part A. This document makes them precise enough to
implement and verify. The register map is in `docs/REGMAP.md`, generated from `scripts/regmap.yaml`.
Items marked **[decision]** fill a gap in the brief and are recorded in `docs/DECISIONS.md` after the
owner's review.

**References:**
- **ARM IHI 0024E**, *AMBA APB Protocol Specification* (2023, Non-Confidential).
- **ARM IHI 0068D**, *AMBA Low Power Interface Specification* (2021, Non-Confidential).

Both were read from Arm's documentation service while writing this spec. Section and page numbers
below refer to those issues.

---

## 1. Overview

```
            AON domain (always on)                              switchable domain d (×N_PD)
 APB3 ──► apb_regs ──► mode/target logic ──► pd_ctrl[d] ──┬─ QREQn ──────────────► Q-Channel device
 wake_irq[7:0] ─► wake_ctrl ─┘                ▲           │  QACCEPTn, QDENY, QACTIVE ◄─ (isolated, clamp 0)
                                inrush_arb ───┘           ├─ clk_en ─► ICG (dlclkp) ─► domain clock
                                                          ├─ iso_en ─► isolation cells on domain outputs
                                                          ├─ ret_save / ret_restore ─► retention flops
                                                          ├─ rst_n ──► domain reset
                                                          └─ psw_trickle_en, psw_main_en ─► power switches
                                                             psw_trickle_ack, psw_main_ack ◄─
 irq, pmu_state ◄── status
```

- The PMU sits in the always-on (AON) domain and controls `N_PD` switchable domains (parameter,
  default 3).
  - Domain 0 is `PD_CPU` (with retention), domain 1 `PD_DSP` (with retention), domain 2 `PD_PERI`
    (no retention).
  - A per-domain parameter `HAS_RET[d]` says whether the domain has retention.
- **Clocking [decision]:** one PMU clock (`PCLK`). The domain controllers' Q-Channel signals and the
  power-switch acks are treated as asynchronous (IHI 0068D §2.1.1: "All signals are assumed to be
  asynchronous"). Each passes through a synchroniser of `SYNC_STAGES` flip-flops (parameter,
  default 2) before the FSM uses it.

## 2. Interfaces

### 2.1 APB3 completer (ARM IHI 0024E)
- **Signals:** `PCLK`, `PRESETn`, `PSEL`, `PENABLE`, `PWRITE`, `PADDR[11:0]`, `PWDATA[31:0]`,
  `PRDATA[31:0]`, `PREADY`, `PSLVERR`. These are the APB3 signals (IHI 0024E §2.1, p. 2-16). There is
  no `PPROT`/`PSTRB`, which are APB4 additions.
- **Operating states** (IHI 0024E §4.1, p. 4-34): IDLE → SETUP (`PSEL`=1, `PENABLE`=0, exactly one
  cycle) → ACCESS (`PENABLE`=1), left when `PREADY`=1.
- **Zero wait states:** `PREADY` = `PSEL & PENABLE`, so `PREADY` is high only in the access phase
  (property 7).
- **Writes** (IHI 0024E §3.1, p. 3-20) take effect in the access cycle, only if the address is
  writable and the value is legal.
- **Reads** (§3.3, p. 3-23) return the register in that cycle. `PRDATA` = 0 outside the access phase.
- **Errors** (§3.4, p. 3-25): "PSLVERR is only considered valid during the last cycle of an APB
  transfer, when PSEL, PENABLE, and PREADY are all HIGH". It is driven LOW otherwise, as that section
  recommends. `PSLVERR`=1 for:
  1. an address not in `docs/REGMAP.md`;
  2. a write to an RO register;
  3. a write of an illegal mode value (5–7) to `MODE_REQ` or `WAKE_MODE`.

  The spec allows a write with an error to update state (§3.4). **This design never does [decision]**,
  which is simpler to verify.
- Address bits [1:0] are ignored; registers are word-aligned.

### 2.2 Q-Channel controller, one per domain (ARM IHI 0068D Chapter 2)

The PMU is the *controller*; the domain is the *device* (IHI 0068D §2.1.1, Figure 2-1).

| Signal | Direction (PMU) | Meaning (IHI 0068D §2.1.1, p. 2-18) |
|---|---|---|
| `QREQn[d]` | out | Quiescence request, active LOW. Driven by a register. |
| `QACCEPTn[d]` | in | Device accepts (drives LOW). |
| `QDENY[d]` | in | Device denies (drives HIGH). |
| `QACTIVE[d]` | in | Device has work to do (a hint; independent of the handshake). |

**Interface states** (IHI 0068D Table 2-1, p. 2-22), encoded {QREQn, QACCEPTn, QDENY}:

| QREQn QACCEPTn QDENY | State | Device |
|---|---|---|
| 1 1 0 | Q_RUN | operational; clock and power guaranteed |
| 0 1 0 | Q_REQUEST | operational, asked to quiesce |
| 0 0 0 | Q_STOPPED | quiescent; clock and power **not** guaranteed |
| 1 0 0 | Q_EXIT | clock and power guaranteed after an implementation-defined delay |
| 0 1 1 | Q_DENIED | refuses; controller must deassert QREQn |
| 1 1 1 | Q_CONTINUE | controller has deasserted QREQn after a deny |
| x 0 1 | illegal | — |

**Handshake rules** (IHI 0068D §2.1.2, "Handshake rules", p. 2-23). The PMU obeys the controller
rules, and the testbench/formal environment assumes the device rules:
- **Controller:** QREQn may fall only when QACCEPTn=1 and QDENY=0. QREQn may rise only when
  QACCEPTn and QDENY are both 0, or both 1.
- **Device:** QACCEPTn may fall only when QREQn=0 and QDENY=0, and rise only when QREQn=1 and QDENY=0.
  QDENY may rise only when QREQn=0 and QACCEPTn=1, and fall only when QREQn=1 and QACCEPTn=1.

**Reset rule** (IHI 0068D §2.1.2, "Device reset", p. 2-20):
- "A controller must only assert a device reset when the interface is in the Q_STOPPED state". The
  PMU drives `rst_n[d]`=0 only after Q_STOPPED is reached (or on PMU reset, when the controller and
  device are reset together).
- At reset the device drives QACCEPTn and QDENY LOW. The PMU releases a device from reset with QREQn
  LOW (Q_STOPPED), which is one of the two options §2.1.2 allows.

**Isolation of the device outputs:** the quiescent state has every Q-Channel signal LOW, "to provide
simple default isolation rules" (§2.1.1). The isolation clamp for `QACCEPTn`, `QDENY` and `QACTIVE`
is therefore **0**, which reads as Q_STOPPED while the domain is off.

**QACTIVE policy** (IHI 0068D §2.1.3, p. 2-23): QACTIVE is optional stimulus. **[decision]** This PMU
is software-led: QACTIVE is synchronised and visible on `pmu_state`, but does not start transitions
by itself. Wake-up comes from `wake_irq` and the wake timer (section 7).

### 2.3 Power-control outputs and inputs, per domain

| Signal | Dir | Active | Function |
|---|---|---|---|
| `clk_en[d]` | out | high | Enable of the domain's ICG cell (`sky130_fd_sc_hd__dlclkp`). 0 = clock stopped. |
| `iso_en[d]` | out | high | Isolation cells on every domain output are clamping. |
| `ret_save[d]` | out | high pulse | Retention flops capture (domains with retention only). |
| `ret_restore[d]` | out | high pulse | Retention flops drive their value back (domains with retention only). |
| `rst_n[d]` | out | low | Domain reset. |
| `psw_trickle_en[d]` | out | high | Weak (trickle) power switch on. |
| `psw_main_en[d]` | out | high | Strong (main) power switch on. |
| `psw_trickle_ack[d]` | in | high | Trickle switch reports on. |
| `psw_main_ack[d]` | in | high | Main switch reports on. |

`pwr_good[d]` = `psw_trickle_ack[d] & psw_main_ack[d]` (synchronised), as defined by the brief.

### 2.4 Other ports
- `wake_irq[7:0]` (in, level, asynchronous, synchronised): wake sources.
- `irq` (out): `|(IRQ_STATUS & IRQ_EN)`.
- `pmu_state[]` (out): debug bus with the per-domain FSM states, the arbiter grant and the busy flag.
  The exact layout is in `docs/MICROARCH.md`.

## 3. Domain states and system modes

### 3.1 Stable domain states

| State | Power switches | iso_en | clk_en | rst_n | Q-Channel | Retention flops |
|---|---|---|---|---|---|---|
| ON | on (pwr_good) | 0 | 1 | 1 | Q_RUN | — |
| CLK_GATED | on (pwr_good) | 0 | 0 | 1 | Q_STOPPED | — |
| RET | off | 1 | 0 | 0 | Q_STOPPED (clamped) | hold saved state (`RET_VALID`=1) |
| OFF | off | 1 | 0 | 0 | Q_STOPPED (clamped) | invalid (`RET_VALID`=0) |
| FAULT | see §6 | | | | | |

- **CLK_GATED is unisolated** with `clk_en`=0 (brief, property 2 note): the domain is powered and
  quiescent (Q_STOPPED), so its outputs are stable and need no clamp.
- **RET and OFF** differ only in whether the retention flops hold a saved state. In this model the
  retention flops are supplied from AON, so RET → OFF is bookkeeping only: `RET_VALID` := 0, with no
  output change.
- A domain without retention never enters RET.

### 3.2 System modes (BRIEF A2)

| Mode (`MODE_REQ`) | PD_CPU | PD_DSP | PD_PERI |
|---|---|---|---|
| RUN (0) | ON | ON | ON |
| IDLE (1) | CLK_GATED | CLK_GATED | ON |
| SLEEP (2) | RET | RET | CLK_GATED |
| DEEP_SLEEP (3) | RET | OFF | OFF |
| SHUTDOWN (4) | OFF | OFF | OFF |

**Target satisfaction [decision]:**
- A domain whose target is RET also counts as at target in OFF (for example DEEP_SLEEP → SLEEP leaves
  PD_DSP OFF). Raising OFF to RET would mean powering up only to power down again, with nothing to
  save.
- Every other target must be met exactly.

### 3.3 Domain transitions

Each domain moves between stable states by these sequences (section 4):

| From \ To | ON | CLK_GATED | RET | OFF |
|---|---|---|---|---|
| ON | — | **CG-down** | **PD-down(ret)** | **PD-down** |
| CLK_GATED | **CG-up** | — | PD-down(ret) from step 4 | PD-down from step 4 |
| RET | **PU-up(restore)** | PU-up(restore), then CG-down | — | bookkeeping (`RET_VALID`:=0) |
| OFF | **PU-up** | PU-up, then CG-down | stays OFF (satisfies RET) | — |

- Power-up always passes through ON: isolation is released with the clock running (property 2), and
  the device acknowledges Q_EXIT → Q_RUN.
- A domain that must power up to CLK_GATED therefore goes to ON first, then quiesces again.

## 4. Sequences

Each step either *acts* (changes outputs, then holds for a `DLY_*` count) or *waits* (for an
acknowledge, bounded by a `TMO_*` count). All delays count PMU clock cycles; a programmed 0 is
treated as 1. The step numbers follow the brief.

### 4.1 Power-down (ON → RET or OFF)

| # | Brief step | Action / wait | Delay / timeout | Q-Channel state after |
|---|---|---|---|---|
| 1 | Q-channel quiesce request | QREQn := 0 | — | Q_REQUEST |
| 2 | wait accept, or abort on deny | wait QACCEPTn=0 → continue; QDENY=1 → **deny abort** (4.5) | `TMO_QCH` (fault step QACCEPT_DOWN) | Q_STOPPED |
| 3 | `clk_en`=0 | clk_en := 0 | `DLY_CLK` | |
| 4 | `iso_en`=1 | iso_en := 1 | `DLY_ISO` | |
| 5 | `ret_save` | if `HAS_RET[d]` and target = RET: ret_save := 1 for `DLY_RET` cycles, then 0; `RET_VALID` := 1 | `DLY_RET` | |
| 6 | `rst_n`=0 | rst_n := 0 | `DLY_RST` | (device reset in Q_STOPPED: allowed) |
| 7a | main switch off | psw_main_en := 0; wait psw_main_ack=0 | `TMO_PSW` (PSW_MAIN_OFF) | |
| 7b | then trickle switch off | psw_trickle_en := 0; wait psw_trickle_ack=0 | `TMO_PSW` (PSW_TRICKLE_OFF) | |
| 8 | wait `psw_ack`=0 | both acks 0 → state RET (if saved) or OFF | | |

- **CLK_GATED → RET/OFF** starts at step 4: the device is already in Q_STOPPED with the clock off.
- **Target OFF** skips the save in step 5. Going ON → OFF in a retention domain sets `RET_VALID` := 0.

### 4.2 Clock gating (ON ↔ CLK_GATED)

- **CG-down:** steps 1–3 of 4.1 (QREQn := 0, wait accept or deny, clk_en := 0, `DLY_CLK`) → CLK_GATED.
- **CG-up:**
  1. clk_en := 1 and hold `DLY_CLK`;
  2. Q-Channel exit: QREQn := 1 (Q_EXIT), wait QACCEPTn=1 within `TMO_QCH` (fault step QACCEPT_UP)
     → Q_RUN → ON.

### 4.3 Power-up (RET or OFF → ON)

| # | Brief step | Action / wait | Delay / timeout |
|---|---|---|---|
| 0 | inrush arbitration | request the inrush arbiter; wait for the grant (section 5) | — |
| 1 | trickle switch on | psw_trickle_en := 1 | — |
| 2 | wait ack | wait psw_trickle_ack=1, then hold it for `DLY_TRICKLE` cycles (property 4) | `TMO_PSW` (PSW_TRICKLE_ON) |
| 3 | main switch on | psw_main_en := 1 | — |
| 4 | wait ack | wait psw_main_ack=1, then hold `DLY_MAIN` cycles; then **release the inrush grant** | `TMO_PSW` (PSW_MAIN_ON) |
| 5 | `ret_restore` | if `HAS_RET[d]` and `RET_VALID`: ret_restore := 1 for `DLY_RET` cycles; then `RET_VALID` := 0 | `DLY_RET` |
| 6 | `rst_n`=1 | rst_n := 1 (the device leaves reset in Q_STOPPED, IHI 0068D §2.1.2) | `DLY_RST` |
| 7 | `clk_en`=1 | clk_en := 1 | `DLY_CLK` |
| 8 | `iso_en`=0 | iso_en := 0 (released last; clock running, property 2) | — |
| 9 | Q-channel exit | QREQn := 1 (Q_EXIT); wait QACCEPTn=1 | `TMO_QCH` (QACCEPT_UP) |

- **Restore before reset release [decision]:** the brief's order puts `ret_restore` (step 5) before
  `rst_n`=1 (step 6). The retention flops must therefore load their saved value while the domain's
  normal reset is still asserted, so a retention flop's restore overrides its reset. The domain-shell
  model (Phase 3) implements exactly this. Non-retention registers come out of reset.
- **Restore is skipped when `RET_VALID`=0** (the domain was OFF). The domain then starts from reset.

### 4.4 Inrush rule
The *power-up switching phase* of a domain runs from step 1 (trickle on) to the end of step 4 (main
ack held for `DLY_MAIN`). At most one domain is in that phase at any time (property 5); section 5
describes the arbiter. Power-down switching is not restricted.

### 4.5 Deny abort (IHI 0068D §2.1.2, "Denied quiescence request", Figure 2-3, p. 2-20)
1. In step 2 of 4.1 or 4.2, the device drives QDENY=1 (Q_DENIED).
2. The PMU drives QREQn := 1 (Q_CONTINUE), which the rules allow because QACCEPTn=1 and QDENY=1.
3. The PMU waits for QDENY=0 (Q_RUN) within `TMO_QCH` (fault step QDENY_RELEASE).
4. The domain stays **ON**. `IRQ_STATUS.DENY` is set.

**[decision]** After a deny, the domain does not retry by itself. Its pending request is dropped until
the next write to `MODE_REQ` (or a wake event), and `MODE_STATUS.MISMATCH` is set. This avoids an
endless request/deny loop against a busy device.

### 4.6 Timeouts and FAULT
Every *wait* in 4.1–4.5 has a timeout. When it expires:
- `IRQ_STATUS.FAULT` is set.
- If `FAULT_INFO.VALID`=0, `FAULT_INFO` records the domain and step.
- The domain enters **FAULT**.

FAULT outputs depend on which kind of wait failed **[decision]**:
- **Power-switch timeout** (PSW_*): the domain is put in the safe off configuration: both switch
  enables 0, `iso_en`=1, `clk_en`=0, `rst_n`=0. Retention is not saved, but `RET_VALID` is kept if it
  was already 1.
- **Q-Channel timeout** (QACCEPT_DOWN, QDENY_RELEASE, QACCEPT_UP): the outputs are **held as they
  are**.
  - The device has not answered, so it may still be operating. IHI 0068D forbids changing QREQn
    before the handshake completes (§2.1.2 rules; §2.1.3: "QREQn cannot be driven HIGH until the
    handshake is completed").
  - It also forbids asserting reset outside Q_STOPPED (§2.1.2, "Device reset").
  - Forcing isolation or reset here would break the protocol.

**Recovery:**
- Writing 1 to `IRQ_STATUS.FAULT` clears FAULT and `FAULT_INFO`.
- A PSW-faulted domain then becomes **OFF**.
- A Q-faulted domain resumes the same wait with a fresh timeout.
- Each domain then moves toward the current `MODE_REQ` target again.

## 5. Inrush arbiter
- **Requesters:** each domain that reaches power-up step 0.
- **Grant:** fixed priority **CPU (0) > DSP (1) > PERI (2)**, lowest index first. A grant is held
  until the holder releases it at the end of step 4 (or enters FAULT).
- **No preemption:** the grant is never taken away from its holder.
- **Starvation:** a lower-priority domain waits at most for the higher-priority domains' switching
  phases. Each is bounded by `2×TMO_PSW + DLY_TRICKLE + DLY_MAIN` plus a few cycles, so waiting is
  bounded (property 9). Only domains requesting power-up compete; a domain is granted at most once
  per power-up.
- **Why this order:** the CPU must run first to serve the other domains' wake-up handling. The
  peripheral domain is the most tolerant of latency.

## 6. Requests while busy, and wake-up races
- **Newest request wins:** `MODE_REQ` may be written at any time (including by a wake event). Each
  domain's target becomes the new mode's state for it.
- **[decision]** A domain in the middle of a sequence **completes that sequence** to the stable state
  it was heading for, and then starts towards the newest target. It is never reversed mid-sequence.
  - **Exceptions:** a deny (4.5) and a FAULT (4.6).
  - **Why:** this keeps every sequence atomic and in protocol order, so properties 1–6 hold in every
    interleaving. A wake request during a power-down costs at most one complete power-down plus one
    power-up.
- **Wake during power-down (the brief's race test):** the domain finishes the power-down, then powers
  up again. `IRQ_STATUS.DONE` fires when every domain is at the final target.
- `MODE_STATUS.BUSY`=1 while any domain is not at a stable state or not at its target (and has a
  pending request).
- `MODE_STATUS.MODE` updates when every domain satisfies the requested mode; `IRQ_STATUS.DONE` is set
  at that moment.

## 7. Wake-up
- **Wake events:**
  - `wake_irq[i]` rising (after synchronisation) with `WAKE_MASK[i]`=0;
  - the wake timer reaching `WAKE_TIMER_CMP` while `WAKE_CTRL.TIMER_EN`=1. The timer is one-shot:
    `TIMER_EN` is cleared when the compare fires.
- **On a wake event:** `IRQ_STATUS.WAKE` := 1 and `MODE_REQ` := `WAKE_MODE` (the same effect as a
  software write).
- **Simultaneous events** (several `wake_irq` bits and the timer in one cycle) are one wake event: the
  target is the same, and the source bits are visible as the inputs. A wake while already at
  `WAKE_MODE` only sets `IRQ_STATUS.WAKE`.
- **Edge detection [decision]:** wake on a rising edge, so a level that stays high does not keep
  re-requesting `WAKE_MODE` after software chooses another mode.
- **Timer:** a 32-bit up-counter in the AON domain, counting PMU clock cycles. Writing
  `WAKE_CTRL.TIMER_EN`=1 clears the count and starts it.

## 8. Reset
- **`PRESETn`** (active LOW) is the only PMU reset: asserted asynchronously, released synchronously
  (the strategy is detailed in Phase 2, `docs/DECISIONS.md`).
- **During and right after reset**, every domain is OFF:
  - QREQn=0, `clk_en`=0, `iso_en`=1, `rst_n`=0, switch enables 0, no save or restore;
  - every register at its reset value from `docs/REGMAP.md`.
- **Boot:** `MODE_REQ` resets to RUN, so after reset the PMU powers up every domain in arbiter order
  without any software action.

## 9. Formal properties (BRIEF A3), as they apply to this spec

| # | Property | Spec section |
|---|---|---|
| 1 | `!pwr_good[d] → iso_en[d] && !clk_en[d] && !rst_n[d]` | 3.1, 4.1 (steps 3–6 come before switch-off), 4.3 (steps 6–8 after switch-on) |
| 2 | `!iso_en[d] → pwr_good[d] && rst_n[d]`; `$fell(iso_en[d]) → clk_en[d]` | 4.3 step 8 |
| 3 | `ret_save[d] → iso_en[d] && !clk_en[d]` | 4.1 step 5 |
| 4 | `$rose(psw_main_en[d])` only after `psw_trickle_ack[d]` high for ≥ `DLY_TRICKLE` cycles | 4.3 step 2 |
| 5 | at most one domain in the power-up switching phase | 4.4, 5 |
| 6 | Q-Channel controller rules; device rules assumed | 2.2 |
| 7 | APB: `PREADY`/`PSLVERR` only in the access phase; registers change only on a valid write | 2.1 |
| 8 | every FSM in a legal state | Phase 2 encodings |
| 9 | bounded liveness: with acks within K cycles, every request reaches its target or FAULT within a stated bound | 5, 6; the bound is derived in Phase 3 |

- Property 1 is evaluated on the PMU's synchronised `pwr_good`.
- "Inputs held stable" assumptions (the switch model never drops an ack without a request) are
  stated in `formal/` in Phase 3.

## 10. Timing diagrams (WaveDrom)

Each diagram shows the order of the outputs and the waits for one domain. One period stands for "one
or more cycles": every `DLY_*` hold and every wait. The JSON renders at <https://wavedrom.com/editor.html>.

### 10.1 Power-down ON → RET (with retention)
```wavedrom
{ "signal": [
  {"name": "step", "wave": "222222222222", "data": ["ON", "1:QREQn↓", "2:wait", "3:clk", "4:iso", "5:save", "6:rst", "7a:main", "ack", "7b:trickle", "ack", "RET"]},
  {"name": "QREQn", "wave": "10.........."},
  {"name": "QACCEPTn", "wave": "1.0........."},
  {"name": "QDENY", "wave": "0..........."},
  {"name": "clk_en", "wave": "1..0........"},
  {"name": "iso_en", "wave": "0...1......."},
  {"name": "ret_save", "wave": "0....10....."},
  {"name": "rst_n", "wave": "1.....0....."},
  {"name": "psw_main_en", "wave": "1......0...."},
  {"name": "psw_main_ack", "wave": "1.......0..."},
  {"name": "psw_trickle_en", "wave": "1........0.."},
  {"name": "psw_trickle_ack", "wave": "1.........0."}
]}
```

### 10.2 Power-down ON → OFF (no save) and CLK_GATED → OFF
Same as 10.1 with `ret_save` held at 0. From CLK_GATED the sequence starts at step 4: QREQn,
QACCEPTn and `clk_en` are already 0.
```wavedrom
{ "signal": [
  {"name": "step", "wave": "22222222222", "data": ["ON", "1:QREQn↓", "2:wait", "3:clk", "4:iso", "6:rst", "7a:main", "ack", "7b:trickle", "ack", "OFF"]},
  {"name": "QREQn", "wave": "10........."},
  {"name": "QACCEPTn", "wave": "1.0........"},
  {"name": "clk_en", "wave": "1..0......."},
  {"name": "iso_en", "wave": "0...1......"},
  {"name": "ret_save", "wave": "0.........."},
  {"name": "rst_n", "wave": "1....0....."},
  {"name": "psw_main_en", "wave": "1.....0...."},
  {"name": "psw_main_ack", "wave": "1......0..."},
  {"name": "psw_trickle_en", "wave": "1.......0.."},
  {"name": "psw_trickle_ack", "wave": "1........0."}
]}
```

### 10.3 Power-up RET → ON (with restore) and OFF → ON
From OFF (`RET_VALID`=0), `ret_restore` stays 0 and the domain starts from reset.
```wavedrom
{ "signal": [
  {"name": "step", "wave": "2222222222222", "data": ["RET", "0:grant", "1:trickle", "2:ack+DLY", "3:main", "4:ack+DLY", "release", "5:restore", "6:rst", "7:clk", "8:iso", "9:Q exit", "ON"]},
  {"name": "inrush_grant", "wave": "01....0......"},
  {"name": "psw_trickle_en", "wave": "0.1.........."},
  {"name": "psw_trickle_ack", "wave": "0..1........."},
  {"name": "psw_main_en", "wave": "0...1........"},
  {"name": "psw_main_ack", "wave": "0....1......."},
  {"name": "ret_restore", "wave": "0......10...."},
  {"name": "rst_n", "wave": "0.......1...."},
  {"name": "clk_en", "wave": "0........1..."},
  {"name": "iso_en", "wave": "1.........0.."},
  {"name": "QREQn", "wave": "0..........1."},
  {"name": "QACCEPTn", "wave": "0...........1"}
]}
```
`psw_main_en` rises only after `psw_trickle_ack` has been high for `DLY_TRICKLE` cycles (property 4).
The grant is released after `psw_main_ack` has been high for `DLY_MAIN` cycles.

### 10.4 Clock gating ON → CLK_GATED → ON
```wavedrom
{ "signal": [
  {"name": "step", "wave": "2222222222", "data": ["ON", "1:QREQn↓", "2:accept", "3:clk off", "CLK_GATED", "…", "clk on", "Q exit", "accept", "ON"]},
  {"name": "QREQn", "wave": "10.....1.."},
  {"name": "QACCEPTn", "wave": "1.0.....1."},
  {"name": "clk_en", "wave": "1..0..1..."},
  {"name": "iso_en", "wave": "0........."},
  {"name": "rst_n", "wave": "1........."}
]}
```

### 10.5 Deny abort (IHI 0068D Figure 2-3)
```wavedrom
{ "signal": [
  { "name": "Q state",  "wave": "2222.2", "data": ["Q_RUN","Q_REQUEST","Q_DENIED","Q_CONTINUE","Q_RUN"] },
  { "name": "QREQn",    "wave": "10.1.." },
  { "name": "QACCEPTn", "wave": "1....." },
  { "name": "QDENY",    "wave": "0.1..0" },
  { "name": "clk_en",   "wave": "1....." },
  { "name": "irq DENY", "wave": "0..1.." }
]}
```

### 10.6 Power-switch timeout → FAULT (power-up, main switch never acknowledges)
```wavedrom
{ "signal": [
  { "name": "step",            "wave": "2.2.2...2", "data": ["trickle ok","main on","wait (TMO_PSW)","FAULT"] },
  { "name": "psw_trickle_en",  "wave": "1.......0" },
  { "name": "psw_main_en",     "wave": "0.1.....0" },
  { "name": "psw_main_ack",    "wave": "0........" },
  { "name": "iso_en",          "wave": "1........" },
  { "name": "rst_n",           "wave": "0........" },
  { "name": "IRQ_STATUS.FAULT","wave": "0.......1" }
]}
```

## 11. Out of scope
- **No multi-voltage:** all domains share one supply voltage, so there are no level shifters (legacy
  item 6 in `docs/AUDIT.md`).
- **No layout of the switchable domains:** the open flow cannot implement power switches, isolation
  in a separate supply or retention flops. Only the PMU (AON logic) goes through LibreLane. The
  domains exist as behavioural shells in simulation (BRIEF A3, A4).
- **No DVFS, no voltage scaling, no retention-supply switching.**
