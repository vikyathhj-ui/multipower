# What I learned

Notes in my own words, phase by phase. Decisions are in `docs/DECISIONS.md`; numbers are in
`results/`.

## Phase 0–1 — Power intent and the Q-Channel

### Why the ordering matters
- **Power-down: clock off → isolate → save → reset → switches off.**
  - The clock stops first, so nothing is mid-operation.
  - Isolation comes next, because once the supply starts to drop the domain's outputs float or go
    to garbage, and the always-on logic must not see that.
  - Retention is saved while the logic is still powered and quiet.
  - Reset is asserted before power-off, so power-up starts from a known state.
- **Power-up is the mirror image, and isolation is released last:** only when the domain is powered,
  out of reset and clocked are its outputs meaningful again.

### Staged switches and inrush
- Turning on a large power switch at once charges the whole domain's capacitance in one go. That
  current spike (inrush) can dip the supply for every other domain.
- A weak trickle switch charges the domain slowly first; the main switch then closes with little
  voltage across it.
- The arbiter lets only one domain do this at a time.

### Q-Channel (ARM IHI 0068D §2.1)
- **Four signals:** QREQn from the controller; QACCEPTn, QDENY and QACTIVE from the device.
- **Six legal states.** Every handshake step changes exactly one signal, which makes it safe across
  clock domains.
- **Deny** lets a busy device refuse to stop without hanging the controller: the controller must
  then raise QREQn again.
- **All-LOW quiescent state:** isolation clamps on the device's outputs are simply 0.
- **Reset rule:** the controller may reset the device only in Q_STOPPED.

### Reading the legacy design (AUDIT)
- A testbench with 24 PASS lines can check almost nothing: 14 of its checks could not fail.
- Before trusting a check, ask what bug would make it fail.

## Phase 2 — RTL
- **Synchronisers:** every signal from another clock or power domain gets one, and the logic must
  remember that the synchronised value is old. Formal found the consequence (F-001).
- **ICG instead of an AND gate:** an AND gate on a clock glitches if the enable changes while the
  clock is high. The ICG latches the enable while the clock is low, so pulses are only ever whole.
- **Generators need checking too:** YAML read the names `ON`/`OFF` as booleans (D-011).

## Phase 3 — Formal and simulation

### Immediate vs concurrent assertions
- **Immediate:** `assert (cond)` inside an `always` block, checked when the block runs.
- **Concurrent:** SVA such as `assert property (a |-> ##1 b)`, a temporal relation clocked over
  cycles.
- **What I used:** immediate assertions plus `$past`, as the brief asks, which is enough for
  one-cycle relations. yosys-slang does not support `$rose`/`$fell`/`$onehot0`, so I wrote them
  with `$past`.

### Bounded vs unbounded proofs
- **BMC (bounded):** "no failure within N cycles of reset". It finds bugs, but says nothing beyond N.
- **k-induction (unbounded):** also proves "if the property held for k steps, it holds in the
  next". That covers *every* reachable state.
- **The catch:** the induction step starts from arbitrary states, including unreachable ones. It
  then fails until you state the invariants that rule them out (h1–h7). Each invariant is proven
  too, so it adds knowledge, not assumptions.
- **Liveness ("eventually") can't be proven by induction directly.** I split it into "each step
  ends within its bound" pieces, which are safety properties, and added the bounds up.

### Counterexamples are bug reports
- **F-001** was a real RTL bug: a stale ack through a synchroniser. I would not have thought to
  simulate the case (reset while the switches are on, with tiny hold delays).
- **The other three** were bugs in *my* assumptions and properties. Formal checks the checker as
  much as the design.

### Mutation testing keeps the verification honest
- **Two checks were weaker than they looked:**
  - P7 reused the design's own write decode (F-005);
  - the scoreboard ignored timing, so same-cycle steps passed.
- **The first mutation run was meaningless:** the harness crashed, and that counted as "caught". A
  control run with no mutation is what makes the score mean anything.
- **Simulation and formal catch different things.** Two mutants were caught only by formal until
  I added the cycle check and a directed test.

### Power-aware simulation without a commercial tool
- **X corruption:** Icarus 4-state X stands in for corrupted state. Normal registers become X when
  power drops.
- **Checks:** a clamp that is working shows no X on the always-on side; a missing or mis-ordered
  isolation shows X immediately.
- **Retention** is modelled as a shadow copy that survives power-off. The checker compares the
  restored value with what was there at `ret_save`.

## Phase 4 — UPF, power analysis, layout

### What UPF adds to RTL
- **RTL assumes every gate is always powered.** UPF describes the power architecture: domains,
  supplies, switches, isolation (clamp values, which side), retention (save/restore signals) and
  the legal power states.
- **UPF says *what*, not *when*.** The ordering of the steps is in the PMU, and that is what I
  proved formally.
- **A hand review still finds things:** the power states had to allow OFF wherever the mode table
  says RET.

### Break-even residency
- **A mode only saves energy if you stay long enough** to pay back the cost of entering and
  leaving it. That cost is small for clock gating (about 2 nJ here) and larger for power gating.
- **Temperature dominates leakage:** sky130's average cell leaks about 3000× more at 100 °C than at
  25 °C. The same SoC should choose modes differently when hot.
- **Be careful what you count as overhead:** an always-on block's power is paid in every mode, so
  charging it all to transitions is only an upper bound.

### The open flow
- **The tools pick cells you did not ask for:** the router's repair step used slow delay cells as
  buffers, costing 4 ns. Excluding them closed timing at every corner, with less area.
- **Read the cells on the critical path, not only the slack.**
- **A config default can be silently wrong:** LibreLane passed `-threads None`, so OpenROAD ran on
  one thread.

## Phase 5 — Close
- **Every number in the README is regenerated from `results/summary.json`** by a script, and CI fails
  if it is stale. Copying numbers by hand is how the original project ended up with "4.98 mW".
- **An open item is reported as open:** one formal cover was not reached within the time I gave it.
  Saying so is more useful than a green tick that is not true.
