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
