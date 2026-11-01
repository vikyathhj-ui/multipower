"""cocotb tests for pmu_top (docs/BRIEF.md A3; test plan in docs/VERIFICATION.md).

Every test runs the checkers in tb/pmu_env.py on every cycle (power-aware checks, Q-Channel and
APB rules, inrush, property 4, sequence scoreboard). A test fails if any check fails.

Environment variables: PMU_SEED (default 1), PMU_SOAK (soak requests, default 10000),
PMU_COV_OUT (coverage JSON path, written by the last test).
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

import regmap as rm
from pmu_coverage import Coverage, report
from pmu_env import Cfg, Env, HAS_RET, MODE_TABLE, MODES, N_PD, ST, satisfies

SEED = int(os.environ.get("PMU_SEED", "1"))
COV = Coverage()


async def boot(dut, cfg=None, seed=SEED) -> Env:
    env = Env(dut, cfg, seed)
    env.cov = COV
    await env.start()
    if not await env.wait_stable(3000):
        env.err("boot did not finish")
    return env


def finish(env: Env, name: str, extra: str = ""):
    env.dut._log.info(f"{'PASS' if not env.errors else 'FAIL'} {name}: {env.seq_checked} sequences "
                      f"checked, {len(env.errors)} errors{extra}")
    assert not env.errors, f"{len(env.errors)} errors; first: {env.errors[0]}"


def field(val: int, reg: str, f: str) -> int:
    fd = rm.REGS[reg]["fields"][f]
    return (val & fd["mask"]) >> fd["lsb"]


async def status(env: Env) -> dict:
    ms = await env.apb.rreg("MODE_STATUS")
    return {"mode": field(ms, "MODE_STATUS", "MODE"), "busy": field(ms, "MODE_STATUS", "BUSY"),
            "fault": field(ms, "MODE_STATUS", "FAULT"), "mismatch": field(ms, "MODE_STATUS", "MISMATCH")}


async def irq_clear(env: Env, mask: int = 0xF):
    await env.apb.wreg("IRQ_STATUS", mask)


async def goto(env: Env, mode: str):
    """Reach a mode with a clean status (used to set up the start of a case)."""
    await env.set_mode(mode)
    await irq_clear(env)


def check_states(env: Env, exp: list[int], what: str):
    st = env.states()
    if st != exp:
        env.err(f"{what}: domain states {st}, expected {exp}")


# ------------------------------------------------------------------------------------- tests

@cocotb.test()
async def test_reset_and_registers(dut):
    """Boot to RUN; every register's reset value; read-back of every RW register; W1C."""
    env = await boot(dut)
    check_states(env, [ST["ON"]] * N_PD, "after boot")
    s = await status(env)
    if s != {"mode": MODES["RUN"], "busy": 0, "fault": 0, "mismatch": 0}:
        env.err(f"MODE_STATUS after boot {s}")
    if not field(await env.apb.rreg("IRQ_STATUS"), "IRQ_STATUS", "DONE"):
        env.err("IRQ_STATUS.DONE not set by the boot transition")
    dynamic = {"MODE_STATUS", "PD_STATE", "WAKE_TIMER", "IRQ_STATUS"}
    for name, r in rm.REGS.items():
        v = await env.apb.rreg(name)
        if name not in dynamic and v != r["reset"]:
            env.err(f"{name} reset {v:#010x}, expected {r['reset']:#010x}")
    if (await env.apb.rreg("PD_STATE")) != 0:                       # all ON, nothing retained
        env.err("PD_STATE after boot is not all ON")
    # read-back of RW registers (values that do not start a transition or a timer)
    for name, r in rm.REGS.items():
        if r["access"] != "RW" or name in ("MODE_REQ", "WAKE_CTRL"):
            continue
        for pat in (0xFFFFFFFF, 0xA5A5A5A5, 0x5A5A5A5A):
            val = 3 if name == "WAKE_MODE" else pat & r["mask"]
            await env.apb.wreg(name, 3 if name == "WAKE_MODE" else pat)
            got = await env.apb.rreg(name)
            if got != val:
                env.err(f"{name}: wrote {pat:#x}, read {got:#x}, expected {val:#x}")
        await env.apb.wreg(name, r["reset"])
    await irq_clear(env, 0x1)
    if field(await env.apb.rreg("IRQ_STATUS"), "IRQ_STATUS", "DONE"):
        env.err("IRQ_STATUS.DONE not cleared by writing 1")
    finish(env, "test_reset_and_registers")


@cocotb.test()
async def test_apb_errors(dut):
    """Unmapped addresses, writes to RO registers and illegal mode values return PSLVERR and
    change nothing; misaligned addresses reach the word's register."""
    env = await boot(dut)

    async def snapshot():
        return {n: await env.apb.rreg(n) for n in rm.REGS if n != "WAKE_TIMER"}

    before = await snapshot()
    mapped = {r["addr"] for r in rm.REGS.values()}
    n_unmapped = 0
    for a in range(0, 0x1000, 4):
        if a in mapped:
            continue
        n_unmapped += 1
        v, e = await env.apb.read(a)
        if not e or v != 0:
            env.err(f"read of unmapped {a:#05x}: PSLVERR={e}, PRDATA={v:#x}")
        if not await env.apb.write(a, 0xFFFFFFFF):
            env.err(f"write to unmapped {a:#05x}: no PSLVERR")
    for name, r in rm.REGS.items():
        if r["access"] == "RO" and not await env.apb.wreg(name, 0xFFFFFFFF):
            env.err(f"write to RO register {name}: no PSLVERR")
    for name in ("MODE_REQ", "WAKE_MODE"):
        for bad in (5, 6, 7):
            if not await env.apb.wreg(name, bad):
                env.err(f"{name} = {bad}: no PSLVERR")
    after = await snapshot()
    for n in before:
        if before[n] != after[n]:
            env.err(f"{n} changed after erroring transfers: {before[n]:#x} -> {after[n]:#x}")
    check_states(env, [ST["ON"]] * N_PD, "after illegal MODE_REQ values")
    v, e = await env.apb.read(rm.ADDR["ID"] + 2)                      # bits [1:0] ignored
    if e or v != rm.REGS["ID"]["reset"]:
        env.err(f"misaligned read of ID: {v:#x}, PSLVERR={e}")
    finish(env, "test_apb_errors", f" ({n_unmapped} unmapped addresses)")


@cocotb.test()
async def test_transition_matrix(dut):
    """Every mode-to-mode transition (5x5), with the end state, MODE_STATUS and DONE checked."""
    env = await boot(dut, Cfg(write_p=0.4))
    cur = "RUN"
    for frm in MODES:
        for to in MODES:
            if cur != frm:
                await goto(env, frm)
                cur = frm
            await irq_clear(env)
            before = env.states()
            await env.set_mode(to)
            check_states(env, env.expect_states(before, to), f"{frm} -> {to}")
            s = await status(env)
            if s["mode"] != MODES[to] or s["busy"] or s["mismatch"] or s["fault"]:
                env.err(f"{frm} -> {to}: MODE_STATUS {s}")
            if not field(await env.apb.rreg("IRQ_STATUS"), "IRQ_STATUS", "DONE"):
                env.err(f"{frm} -> {to}: IRQ_STATUS.DONE not set")
            COV.transition(frm, to)
            cur = to
    finish(env, "test_transition_matrix")


# Transitions in which domain d quiesces from ON (SPEC 3.2): (from, to, d)
DENY_CASES = [(f, t, d) for f in ("RUN", "IDLE") for t in MODES for d in range(N_PD)
              if MODE_TABLE[f][d] == ST["ON"] and MODE_TABLE[t][d] != ST["ON"]]


@cocotb.test()
async def test_deny_every_step(dut):
    """A deny at every quiescence request of every domain: the domain stays ON, the others reach
    their targets, DENY and MISMATCH are reported, and a retry without deny succeeds."""
    cfg = Cfg(deny_p=0.0)
    env = await boot(dut, cfg)
    await irq_clear(env)
    await env.apb.wreg("IRQ_EN", 0xF)
    for frm, to, d in DENY_CASES:
        await goto(env, frm)
        cfg.deny_p, cfg.deny_doms = 1.0, (d,)
        before = env.states()
        await env.set_mode(to)
        exp = env.expect_states(before, to)
        exp[d] = ST["ON"]
        check_states(env, exp, f"deny PD{d} in {frm} -> {to}")
        s = await status(env)
        irq = field(await env.apb.rreg("IRQ_STATUS"), "IRQ_STATUS", "DENY")
        if not s["mismatch"] or s["busy"] or not irq or not int(dut.irq.value):
            env.err(f"deny PD{d} in {frm} -> {to}: MODE_STATUS {s}, IRQ DENY {irq}, irq {dut.irq.value}")
        cfg.deny_p = 0.0
        await irq_clear(env)
        await env.set_mode(to)                                        # retry succeeds
        check_states(env, env.expect_states(before, to), f"retry after deny PD{d} {frm} -> {to}")
    await env.apb.wreg("IRQ_EN", rm.REGS["IRQ_EN"]["reset"])
    finish(env, "test_deny_every_step", f" ({len(DENY_CASES)} deny cases)")


# Fault injection points: (Fault.where, FAULT_INFO.STEP name, start mode, request, with deny)
TIMEOUT_CASES = [
    ("qaccept_down",  "QACCEPT_DOWN",    "RUN",      "SHUTDOWN", False),
    ("qdeny_release", "QDENY_RELEASE",   "RUN",      "SHUTDOWN", True),
    ("main_off",      "PSW_MAIN_OFF",    "RUN",      "SHUTDOWN", False),
    ("trickle_off",   "PSW_TRICKLE_OFF", "RUN",      "SHUTDOWN", False),
    ("trickle_on",    "PSW_TRICKLE_ON",  "SHUTDOWN", "RUN",      False),
    ("main_on",       "PSW_MAIN_ON",     "SHUTDOWN", "RUN",      False),
    ("qaccept_up",    "QACCEPT_UP",      "SHUTDOWN", "RUN",      False),
]


@cocotb.test()
async def test_timeout_every_wait(dut):
    """A timeout at every wait step of every domain: FAULT, FAULT_INFO, irq, safe outputs for a
    power-switch fault, then recovery after IRQ_STATUS.FAULT is cleared."""
    cfg = Cfg()
    env = await boot(dut, cfg)
    await env.apb.wreg("TMO_QCH", 40)
    await env.apb.wreg("TMO_PSW", 40)
    for where, step, start, req, deny in TIMEOUT_CASES:
        for d in range(N_PD):
            await goto(env, start)
            cfg.deny_p, cfg.deny_doms = (1.0, (d,)) if deny else (0.0, None)
            env.fault.dom, env.fault.where, env.fault.active, env.fault.hit = d, where, True, False
            await env.request(req)
            for _ in range(2000):
                await RisingEdge(dut.PCLK)
                await ReadOnly()
                if env.states()[d] == ST["FAULT"]:
                    break
            await RisingEdge(dut.PCLK)
            if env.states()[d] != ST["FAULT"]:
                env.err(f"{where} PD{d}: no FAULT (states {env.states()}, injected={env.fault.hit})")
                env.fault.active = False
                continue
            info = await env.apb.rreg("FAULT_INFO")
            irqs = await env.apb.rreg("IRQ_STATUS")
            exp = (1 << 31) | (rm.FAULT_STEP[step] << 4) | d
            if info != exp or not field(irqs, "IRQ_STATUS", "FAULT") or not int(dut.irq.value):
                env.err(f"{where} PD{d}: FAULT_INFO {info:#x} (expected {exp:#x}), IRQ_STATUS "
                        f"{irqs:#x}, irq {dut.irq.value}")
            if not (await status(env))["fault"]:
                env.err(f"{where} PD{d}: MODE_STATUS.FAULT not set")
            COV.fault(d, rm.FAULT_STEP[step])
            if step.startswith("PSW"):                     # safe off configuration (SPEC 4.6)
                await ReadOnly()
                outs = {n: (int(getattr(dut, n).value) >> d) & 1 for n in
                        ("psw_trickle_en", "psw_main_en", "iso_en", "clk_en", "rst_n")}
                if outs != {"psw_trickle_en": 0, "psw_main_en": 0, "iso_en": 1, "clk_en": 0, "rst_n": 0}:
                    env.err(f"{where} PD{d}: FAULT outputs not safe: {outs}")
                await RisingEdge(dut.PCLK)
            env.fault.active = False
            cfg.deny_p = 0.0
            await irq_clear(env, 0x4)                       # clears FAULT: recovery
            if not await env.wait_stable(3000):
                env.err(f"{where} PD{d}: no recovery after clearing FAULT")
            if (await env.apb.rreg("FAULT_INFO")) != 0:
                env.err(f"{where} PD{d}: FAULT_INFO not cleared")
            await env.set_mode(req)                          # finish the request after recovery
            check_states(env, env.expect_states(env.states(), req), f"{where} PD{d} after recovery")
            await irq_clear(env)
    finish(env, "test_timeout_every_wait", f" ({len(TIMEOUT_CASES) * N_PD} timeout cases)")


@cocotb.test()
async def test_wake_race(dut):
    """Wake-up arriving at every point of a power-down sequence (and of a power-up): the
    sequence in progress completes, then the system goes to WAKE_MODE."""
    env = await boot(dut)
    await env.apb.wreg("WAKE_MASK", 0xFE)                 # wake_irq[0] enabled
    for wake_mode, req, start in (("RUN", "SHUTDOWN", "RUN"), ("RUN", "SLEEP", "RUN"),
                                  ("SHUTDOWN", "RUN", "SHUTDOWN")):
        await env.apb.wreg("WAKE_MODE", MODES[wake_mode])
        for delay in range(0, 90, 3):
            await goto(env, start)
            await env.request(req)
            for _ in range(delay):
                await RisingEdge(dut.PCLK)
            dut.wake_irq.value = 1
            for _ in range(4):
                await RisingEdge(dut.PCLK)
            dut.wake_irq.value = 0
            env.mode_req = wake_mode
            if not await env.wait_stable(5000):
                env.err(f"wake at +{delay} during {start}->{req}: not stable")
            exp = env.expect_states(env.states(), wake_mode)
            check_states(env, exp, f"wake at +{delay} during {start}->{req}")
            if not field(await env.apb.rreg("IRQ_STATUS"), "IRQ_STATUS", "WAKE"):
                env.err(f"wake at +{delay}: IRQ_STATUS.WAKE not set")
            if (await env.apb.rreg("MODE_REQ")) != MODES[wake_mode]:
                env.err(f"wake at +{delay}: MODE_REQ not set to WAKE_MODE")
    finish(env, "test_wake_race")


@cocotb.test()
async def test_wake_sources(dut):
    """Mask, simultaneous wake requests (several irq bits and the timer in one cycle), and the
    one-shot wake timer."""
    env = await boot(dut)
    await env.apb.wreg("WAKE_MODE", MODES["RUN"])
    # masked sources do nothing
    await goto(env, "SHUTDOWN")
    await env.apb.wreg("WAKE_MASK", 0xFF)
    dut.wake_irq.value = 0xFF
    for _ in range(40):
        await RisingEdge(dut.PCLK)
    dut.wake_irq.value = 0
    if env.states() != [ST["OFF"]] * N_PD or field(await env.apb.rreg("IRQ_STATUS"), "IRQ_STATUS", "WAKE"):
        env.err("masked wake_irq woke the system")
    # several unmasked bits and the timer compare in the same cycle -> one wake event
    await env.apb.wreg("WAKE_MASK", 0x00)
    await env.apb.wreg("WAKE_TIMER_CMP", 60)
    await env.apb.wreg("WAKE_CTRL", 1)
    simul = False
    for _ in range(200):
        await RisingEdge(dut.PCLK)
        await ReadOnly()
        if int(dut.u_pmu.timer_cnt.value) == 60 - 3:       # 2 sync stages + edge detect: align
            await RisingEdge(dut.PCLK)
            dut.wake_irq.value = 0x0F
            simul = True
            break
    for _ in range(4):
        await RisingEdge(dut.PCLK)
        await ReadOnly()
        if int(dut.u_pmu.wake_evt.value) and int(dut.u_pmu.timer_fire.value):
            simul = simul and True
    await RisingEdge(dut.PCLK)
    dut.wake_irq.value = 0
    env.mode_req = "RUN"
    await env.wait_stable(5000)
    check_states(env, [ST["ON"]] * N_PD, "simultaneous wake")
    if not simul:
        env.err("could not align wake_irq with the timer compare")
    if (await env.apb.rreg("WAKE_CTRL")) != 0:
        env.err("WAKE_CTRL.TIMER_EN not cleared by the compare (one-shot)")
    # timer alone
    await goto(env, "DEEP_SLEEP")
    await env.apb.wreg("WAKE_MASK", 0xFF)
    await env.apb.wreg("WAKE_TIMER_CMP", 100)
    await env.apb.wreg("WAKE_CTRL", 1)
    env.mode_req = "RUN"
    for _ in range(140):
        await RisingEdge(dut.PCLK)
    await env.wait_stable(5000)
    check_states(env, [ST["ON"]] * N_PD, "timer wake")
    if not field(await env.apb.rreg("IRQ_STATUS"), "IRQ_STATUS", "WAKE"):
        env.err("timer wake: IRQ_STATUS.WAKE not set")
    finish(env, "test_wake_sources")


@cocotb.test()
async def test_reset_while_on(dut):
    """PMU reset while the domains are powered (directed regression for formal bug F-001).
    The switches are still on when the PMU leaves reset and then turn off. Their switch-off delay
    is swept so that, in some iteration, an ack falls just before the PMU re-enables the switch;
    DLY_TRICKLE = DLY_MAIN = 1 make the hold short enough to finish on a stale synchronised ack.
    The pin-level power check in the env fails if a domain is released while unpowered."""
    cfg = Cfg(sw_lat=(3, 8))
    env = await boot(dut, cfg)
    n = 0
    for off_delay in range(1, 17):
        for rst_len in (1, 2, 3):
            cfg.sw_lat = (3, 8)
            await env.set_mode("RUN")
            cfg.sw_lat = (off_delay, off_delay)
            await env.pmu_reset(rst_len)
            await env.apb.wreg("DLY_TRICKLE", 1)
            await env.apb.wreg("DLY_MAIN", 1)
            env.dly_trickle = 1
            if not await env.wait_stable(3000):
                env.err(f"off delay {off_delay}, reset {rst_len}: boot did not finish")
            check_states(env, [ST["ON"]] * N_PD, f"off delay {off_delay}, reset {rst_len}")
            n += 1
    env.dly_trickle = rm.REGS["DLY_TRICKLE"]["reset"]
    finish(env, "test_reset_while_on", f" ({n} resets)")


@cocotb.test()
async def test_soak(dut):
    """>= 10^4 random mode requests with random latencies, random delays, occasional denies and
    requests arriving mid-transition; every check runs throughout."""
    n = int(os.environ.get("PMU_SOAK", "10000"))
    cfg = Cfg(q_lat=(0, 8), sw_lat=(1, 8), deny_p=0.05, write_p=0.3)
    env = await boot(dut, cfg, seed=SEED + 7)
    rng = env.rng
    for name, lo, hi in (("DLY_TRICKLE", 1, 6), ("DLY_MAIN", 1, 4), ("DLY_CLK", 1, 3), ("DLY_ISO", 1, 3),
                         ("DLY_RET", 1, 3), ("DLY_RST", 1, 3)):
        await env.apb.wreg(name, rng.randint(lo, hi))
    env.dly_trickle = await env.apb.rreg("DLY_TRICKLE")
    modes = list(MODES)
    checks = 0
    stable_mode = "RUN"
    for i in range(n):
        m = rng.choice(modes)
        mark = len(env.seq_log)
        await env.request(m)
        if rng.random() < 0.35:                              # sometimes wait for completion
            if not await env.wait_stable(5000):
                env.err(f"soak request {i} ({m}) not stable")
                break
            denied = {d for d, k in env.seq_log[mark:] if k == "deny"}
            st = env.states()
            for d in range(N_PD):
                t = MODE_TABLE[m][d]
                if t == ST["RET"] and not HAS_RET[d]:
                    t = ST["OFF"]
                if not satisfies(st[d], t) and not (d in denied and st[d] == ST["ON"]):
                    env.err(f"soak request {i} ({m}): PD{d} in {st[d]}, target {t}")
            COV.transition(stable_mode, m)
            stable_mode = m
            checks += 1
        else:
            for _ in range(rng.randint(0, 150)):
                await RisingEdge(dut.PCLK)
        if env.errors:
            break
    await env.wait_stable(5000)
    finish(env, "test_soak", f" ({n} requests, {checks} end-state checks)")


@cocotb.test()
async def test_zz_coverage_report(dut):
    """Write the functional coverage collected by all tests (runs last)."""
    out = os.environ.get("PMU_COV_OUT")
    if out:
        s = report(Path(out))
        dut._log.info(f"coverage {s['percent']}% ({s['covered']}/{s['bins']} bins)")
