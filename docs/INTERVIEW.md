# Interview preparation

Likely questions, answered with **this project's actual numbers**. Every number comes from a
result file (`results/…`); Phase 4 (UPF, break-even, layout) questions are added in Phase 4.

Required topics (BRIEF rule 7), and where they are answered:

| Topic | Question |
|---|---|
| why isolation comes before power-off | Q2 |
| why isolation is released last | Q3 |
| retention vs state save to memory | Q5 |
| inrush and staged switches | Q6 |
| Q-Channel accept vs deny | Q8 |
| why ICG cells rather than AND gates | Q12 |
| break-even residency | Phase 4 |
| what UPF describes that RTL doesn't | Phase 4 |
| immediate vs concurrent assertions | Q17 |
| bounded vs unbounded proofs | Q18 |

## Power management concepts

**Q1. What does your PMU do, in one minute?**
- It runs in the always-on domain and switches three domains between ON, CLK_GATED, RET and OFF.
  The mode is set over APB: RUN, IDLE, SLEEP, DEEP_SLEEP or SHUTDOWN.
- For each domain it runs the full sequence:
  - a Q-Channel handshake with the domain;
  - clock gating with a sky130 ICG;
  - isolation;
  - retention save and restore;
  - reset;
  - two-stage power switches, with acknowledges and timeouts.
- An arbiter makes sure only one domain powers up at a time.

**Q2. Why must isolation come before power-off?**
- When a domain's supply collapses, its outputs float to intermediate levels or garbage. The
  always-on logic reading them could latch wrong values, or draw crowbar current in its input
  gates.
- Isolation clamps those outputs to a defined value *before* the supply drops. In my sequence
  `iso_en` rises at step 4; the switches open only at step 7.
- Formal property 1 proves that whenever power is not good, the domain is isolated, clock-stopped
  and in reset.

**Q3. Why is isolation released last on power-up?**
- Until the domain is powered, out of reset and clocked, its outputs are not meaningful. Releasing
  isolation earlier passes X or reset-transient values into the always-on logic.
- So the order is switches, restore, reset release, clock, then isolation.
- Property 2 proves `!iso_en → pwr_good && rst_n` and `$fell(iso_en) → clk_en`.
- My simulation also checks that the isolated outputs equal the clamp value exactly, with no X, on
  every cycle.

**Q4. What is CLK_GATED, and why is it not isolated?**
The domain stays powered but its clock is stopped (after a Q-Channel accept). Its outputs are
stable, so there is nothing to isolate. That is why property 2 is not a plain implication on
`clk_en`.

**Q5. Retention vs saving state to memory: what is the difference?**
- **Retention flops** have a small always-powered shadow (balloon latch) beside each flop.
  `ret_save` copies into it, `ret_restore` copies back. It is fast (my `DLY_RET` is 2 cycles) and
  needs no software, but every retained bit costs area and always-on leakage.
- **Saving to memory** means software writes state out to an always-on RAM before power-off and
  reads it back. It costs no special cells, but takes far more time and energy, and the save code
  must run before the domain goes down.
- Retention suits small, critical state such as the CPU's architectural registers.

**Q6. What is inrush current, and how do staged switches help?**
- Closing a large power switch charges the whole domain's capacitance at once. The current spike
  dips the shared supply and can upset other running domains.
- A weak trickle switch charges the domain slowly; the strong main switch closes only after the
  trickle ack has been high for `DLY_TRICKLE` cycles (property 4, proven).
- The arbiter lets only one domain be in this switching phase at a time (property 5, proven).
- **The legacy design claimed inrush protection, but my audit probe showed two domains switching
  on together for 12 cycles while its `inrush_safe` flag read 1.**

## Q-Channel and APB

**Q7. Explain the Q-Channel signals.**
ARM IHI 0068D §2.1:
- **QREQn**, from the controller: active-low quiescence request.
- **QACCEPTn**, from the device: active-low accept.
- **QDENY**, from the device: deny.
- **QACTIVE**, from the device: a hint that it has work.

There are six legal states (Table 2-1). Each handshake step changes one signal, so the interface
is safe across clock domains.

**Q8. Accept vs deny: what happens in each?**
- **Accept:** QACCEPTn falls, the interface is in Q_STOPPED, and the controller may stop the
  clock or power.
- **Deny:** QDENY rises (Q_DENIED). The controller must raise QREQn again (Q_CONTINUE), and the
  device then lowers QDENY (Q_RUN). The device stays operational.
- **In my PMU,** a deny leaves the domain ON and sets `IRQ_STATUS.DENY` and `MODE_STATUS.MISMATCH`.
  It does not retry until software asks again, to avoid a request/deny loop (D-003.2).
- My deny test covers 14 cases: every domain in every transition where it would quiesce.

**Q9. When may the controller reset the device?**
Only in Q_STOPPED, or when controller and device are reset together (IHI 0068D §2.1.2). My
power-down asserts `rst_n` only after the accept, and the simulation checks this on every reset
edge.

**Q10. Why does your PMU synchronise the Q-Channel and switch inputs, and what did that cause?**
- The signals are asynchronous (IHI 0068D §2.1.1), so each passes through a 2-flop synchroniser.
- Formal found a bug from that (F-001). After a PMU reset with the switches still on, the
  synchronised ack still showed 1 for 2 cycles after the real ack had fallen. The PMU powered a
  domain up on that stale value and released its reset while the supply was off.
- Fix: trust an ack only `SYNC_STAGES` cycles after the enable changed.

**Q11. How does your APB interface handle errors?**
- `PSLVERR` is driven only in the access phase (IHI 0024E §3.4), for:
  - an unmapped address (I test all 1003 unmapped word addresses);
  - a write to a read-only register;
  - an illegal mode value.
- An erroring write changes nothing. That is stricter than the spec requires (D-003.9), and
  formal property 7 proves it.

## Design

**Q12. Why use an ICG cell instead of an AND gate for clock gating?**
An AND gate on a clock glitches if the enable changes while the clock is high: you get a short,
truncated pulse. An ICG (`sky130_fd_sc_hd__dlclkp`) latches the enable while the clock is low, so
the gated clock only ever has whole pulses. Timing tools also understand ICG cells as clock gates.

**Q13. Binary or one-hot FSM, and why?**
Binary: 22 states in 5 flops per domain. The PMU is always on, so its flops leak in every
low-power mode. Timing is not critical, and "legal state" becomes one easy comparison for formal
(D-005).

**Q14. What happens on a timeout?**
- The domain enters FAULT, `IRQ_STATUS.FAULT` is set and `FAULT_INFO` records the domain and step.
- **Switch timeout:** the domain is forced into the safe off state.
- **Q-Channel timeout:** outputs are held, because IHI 0068D forbids changing QREQn or asserting
  reset mid-handshake.
- Clearing the IRQ recovers.
- My test injects a timeout at all 7 wait steps of all 3 domains (21 cases) and checks recovery.

**Q15. A wake-up arrives in the middle of a power-down. What happens?**
The domain finishes the power-down, then powers up to `WAKE_MODE` (D-003.1). A sequence is never
reversed halfway, which keeps every proven ordering property valid in every interleaving. My wake
race test fires the wake every 3 cycles across whole power-down and power-up sequences.

## Verification

**Q16. How did you verify the PMU?**
- **Formal:** properties 1–8 are proven for all reachable states (k-induction). Property 9 is
  proven as per-state time bounds; the end-to-end bound is 2874 cycles at reset configuration.
- **Simulation:** cocotb with behavioural domain shells (X on power loss), a Q-Channel device model
  and switch models with fault injection, and a sequence scoreboard.
  - The 10,000-request random soak checked 20,779 sequences with 0 errors.
  - Functional coverage is 100% of 137 bins.
- **Mutation:** a control run plus 11 deliberate bugs, all caught.

**Q17. Immediate vs concurrent assertions?**
- **Immediate:** `assert (expr)` in procedural code, checked when that code runs.
- **Concurrent:** SVA properties with clocked temporal operators (`a |-> ##[1:3] b`).
- **What I used:** immediate assertions with `$past` (as the brief asks), because the open
  yosys-slang flow supports them well. I wrote `$rose`/`$fell`/`$onehot0` by hand, since
  yosys-slang lacks them.

**Q18. Bounded vs unbounded proofs?**
- **Bounded (BMC):** no counterexample within N cycles of reset. Good for finding bugs, silent
  about N+1.
- **Unbounded (k-induction):** also proves that k good steps imply the next one is good, so the
  property holds forever.
- **The catch:** the induction step starts from arbitrary, even unreachable, states. My first
  attempts failed until I added invariants (h1–h7), each one proven as well.

**Q19. How do you prove "eventually" with a safety checker?**
- I split property 9 into safety pieces:
  - each transient state ends within its bound;
  - an off-target stable state is left in one cycle;
  - a free arbiter grant goes out in one cycle.
- Adding the bounds along the longest path gives 2874 cycles: finish a power-down 776, arbiter wait
  1051, power-up 787, clock-gate 259, plus 1 for leaving a stable state.
- The bound uses timeouts, so it holds even if an ack never arrives: then the domain ends in FAULT.

**Q20. What did formal find?**
- **F-001:** the stale-ack RTL bug (Q10).
- **F-002:** a gap in my device assumption: it allowed QACCEPTn to rise in the reset-release cycle.
- **F-003:** an overflow in my own monitor.
- **F-005:** a property that reused the design's write decode, so it agreed with a bug.

Each counterexample trace is in `results/formal_cex/`.

**Q21. How do you know your testbench can catch bugs?**
- **Mutation testing:** 11 deliberate bugs (e.g. isolation released early, no retention save,
  arbiter without hold, QREQn rule violated, erroring write takes effect). Every one makes the suite
  fail, and the 5 that also run the proof fail it too.
- **The first mutation run was invalid:** a copy filter dropped a testbench file and the crashes
  counted as catches. Now a control run must pass first.

**Q22. How do you simulate power gating without a power-aware simulator?**
- The domain shells set every non-retained register to X when the switch acks drop (Icarus
  4-state). Retention registers keep an always-on shadow.
- The environment checks:
  - the isolated outputs equal the clamp value exactly;
  - no X appears once isolation is released;
  - after power-up, normal registers hold their reset values and retention registers hold what was
    saved.
- **The limit:** these are behavioural models, not a UPF-driven simulation.

**Q23. What was wrong with the original project?**
- The "handshake" was a counter with no acknowledge inputs.
- 14 of 24 PASS checks could not fail.
- "4.98 mW" and "75.9% leakage reduction" were typed into the testbench.
- The "level shifters" were wires.
- The inrush protection did not work.

All with file:line evidence in `docs/AUDIT.md`.
