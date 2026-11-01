"""cocotb environment for pmu_top (docs/BRIEF.md A3, docs/SPEC.md).

Components (all on PCLK; one instance per domain where it applies):
  Apb            APB3 requester (IHI 0024E 3.1/3.3) and a protocol monitor (PREADY/PSLVERR only in
                 the access phase)
  QDevice        Q-Channel device model: follows the IHI 0068D 2.1.2 device rules, acts only while
                 its domain clock runs and the domain is powered and out of reset; configurable
                 latency and deny probability; fault injection (no response at a chosen point)
  Switch         power-switch model: ack follows the enable after a random delay; fault injection
                 (ack stuck at a chosen edge)
  DomainDriver   writes random data into the domain shell while the domain runs; tracks what the
                 retention registers must hold
  Checkers       power-aware checks (isolation, X, retention, reset), the Q-Channel controller
                 rules, inrush (one domain switching on), trickle settle time (property 4), and a
                 sequence scoreboard comparing each completed sequence with docs/SPEC.md section 4
Errors are collected in Env.errors; tests fail if any are recorded.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ReadOnly, RisingEdge, Timer

import regmap as rm

N_PD = rm.N_PD
HAS_RET = [1, 1, 0]
W, N_NORM, N_RET = 8, 4, 2
RB = (N_NORM + N_RET) * W
MODES = rm.MODE                      # name -> code
MODE_NAMES = {v: k for k, v in MODES.items()}
# SPEC 3.2: per-domain target state per mode (ON 0, CLK_GATED 1, RET 2, OFF 3)
MODE_TABLE = {"RUN": (0, 0, 0), "IDLE": (1, 1, 0), "SLEEP": (2, 2, 1), "DEEP_SLEEP": (2, 3, 3),
              "SHUTDOWN": (3, 3, 3)}
ST = {"ON": 0, "CG": 1, "RET": 2, "OFF": 3, "FAULT": 4}
STABLE = {0, 1, 2, 3}


def bit(sig, i: int) -> int:
    """Bit i of a vector signal: 0/1, or -1 for X/Z. str() of a cocotb 2 value is MSB-first."""
    s = str(sig.value)
    c = s[len(s) - 1 - i]
    return int(c) if c in "01" else -1


def bits(sig, lo: int, n: int):
    """Slice [lo+n-1:lo] as a string of '0'/'1'/'x'/'z' (MSB first)."""
    s = str(sig.value)
    L = len(s)
    return s[L - lo - n: L - lo]


def satisfies(state: int, target: int) -> bool:
    return state == target or (target == ST["RET"] and state == ST["OFF"])


@dataclass
class Cfg:
    q_lat: tuple = (0, 6)            # device response latency range (cycles)
    deny_p: float = 0.0              # probability the device denies a quiescence request
    deny_doms: tuple | None = None   # domains whose device may deny (None = all)
    sw_lat: tuple = (1, 6)           # switch ack delay range (cycles)
    write_p: float = 0.3             # probability of a domain register write per running cycle


@dataclass
class Fault:
    """Injected failure for one domain while active: 'qaccept_down', 'qdeny_release', 'qaccept_up'
    (the device stays silent at that point) or 'trickle_on', 'main_on', 'main_off', 'trickle_off'
    (that switch edge is never acknowledged). A test clears `active` to let the model recover."""
    dom: int = -1
    where: str = ""
    active: bool = False
    hit: bool = False

    def at(self, dom: int, where: str) -> bool:
        if self.active and self.dom == dom and self.where == where:
            self.hit = True
            return True
        return False


class Apb:
    def __init__(self, dut, env):
        self.dut, self.env = dut, env

    async def _xfer(self, addr: int, write: bool, data: int = 0):
        d = self.dut
        await RisingEdge(d.PCLK)
        d.PSEL.value, d.PENABLE.value, d.PWRITE.value = 1, 0, int(write)
        d.PADDR.value, d.PWDATA.value = addr, data
        await RisingEdge(d.PCLK)
        d.PENABLE.value = 1
        await ReadOnly()
        while not int(d.PREADY.value):
            await RisingEdge(d.PCLK)
            await ReadOnly()
        rdata, err = int(d.PRDATA.value), int(d.PSLVERR.value)
        await RisingEdge(d.PCLK)
        d.PSEL.value, d.PENABLE.value = 0, 0
        self.env.cov_reg(addr, write, err)
        return rdata, err

    async def write(self, addr: int, data: int) -> int:
        return (await self._xfer(addr, True, data))[1]

    async def read(self, addr: int):
        return await self._xfer(addr, False)

    async def wreg(self, name: str, data: int) -> int:
        return await self.write(rm.ADDR[name], data)

    async def rreg(self, name: str) -> int:
        v, err = await self.read(rm.ADDR[name])
        if err:
            self.env.err(f"read {name} returned PSLVERR")
        return v


class Env:
    def __init__(self, dut, cfg: Cfg | None = None, seed: int = 1):
        self.dut = dut
        self.cfg = cfg or Cfg()
        self.rng = random.Random(seed)
        self.apb = Apb(dut, self)
        self.errors: list[str] = []
        self.cycle = 0
        self.fault = Fault()
        self.events: list[list[tuple]] = [[] for _ in range(N_PD)]   # per-domain output changes
        self.seq_checked = 0
        self.seq_log: list[tuple] = []                                # (dom, kind) completed
        self.ret_written = [[0] * N_RET for _ in range(N_PD)]          # live retention values
        self.ret_saved = [[0] * N_RET for _ in range(N_PD)]            # shadow model
        self.cov = None                                                # set by the test
        self.restored = [False] * N_PD
        self.mode_req = "RUN"                                          # last requested mode
        self.after_fault = [False] * N_PD                              # sequence resumed after FAULT
        self.last_stable = [ST["OFF"]] * N_PD
        self.qdev_state = [dict(acc=0, deny=0, wait=0, act=None) for _ in range(N_PD)]
        self.sw = [dict(trk=0, main=0, t_wait=0, m_wait=0) for _ in range(N_PD)]
        self.trk_hi = [0] * N_PD
        self.dly_trickle = rm.REGS["DLY_TRICKLE"]["reset"]

    # ----------------------------------------------------------------- utilities
    def err(self, msg: str):
        if len(self.errors) < 50:
            self.dut._log.error(f"[cycle {self.cycle}] {msg}")
        self.errors.append(msg)

    def cov_reg(self, addr, write, err):
        if self.cov:
            self.cov.reg_access(addr, write, err)

    async def start(self):
        d = self.dut
        cocotb.start_soon(Clock(d.PCLK, 10, unit="ns").start())
        for name in ("PSEL", "PENABLE", "PWRITE", "PADDR", "PWDATA", "QACCEPTn", "QDENY", "QACTIVE",
                     "psw_trickle_ack", "psw_main_ack", "wake_irq", "dom_wr_en", "dom_wr_idx",
                     "dom_wr_data"):
            getattr(d, name).value = 0
        d.PRESETn.value = 0
        for _ in range(3):
            await RisingEdge(d.PCLK)
        d.PRESETn.value = 1
        cocotb.start_soon(self._run())

    async def _run(self):
        d = self.dut
        prev = None
        while True:
            await RisingEdge(d.PCLK)
            await ReadOnly()
            self.cycle += 1
            snap = self._sample()
            self._check_apb()
            self._check_cycle(snap, prev)
            prev = snap
            await Timer(1, unit="ps")            # leave the read-only phase before driving
            self._drive(snap)

    # ----------------------------------------------------------------- sampling
    def _sample(self):
        d = self.dut
        s = {}
        for name in ("QREQn", "QACCEPTn", "QDENY", "clk_en", "iso_en", "ret_save", "ret_restore",
                     "rst_n", "psw_trickle_en", "psw_main_en", "psw_trickle_ack", "psw_main_ack"):
            s[name] = [bit(getattr(d, name), i) for i in range(N_PD)]
        ps = str(d.pmu_state.value)
        L = len(ps)
        s["st"] = [int(ps[L - 7 * i - 5: L - 7 * i], 2) for i in range(N_PD)]
        s["gnt"] = [int(ps[L - 7 * i - 6]) for i in range(N_PD)]
        s["regs_iso"] = [bits(d.dom_regs_iso, RB * i, RB) for i in range(N_PD)]
        s["rdy_iso"] = [bit(d.dom_rdy_n_iso, i) for i in range(N_PD)]
        s["shadow"] = [bits(d.dom_shadow, N_RET * W * i, N_RET * W) for i in range(N_PD)]
        return s

    def _check_apb(self):
        d = self.dut
        acc = int(d.PSEL.value) and int(d.PENABLE.value)
        if int(d.PREADY.value) != acc:
            self.err("APB: PREADY outside the access phase (IHI 0024E 4.1)")
        if int(d.PSLVERR.value) and not acc:
            self.err("APB: PSLVERR outside the access phase (IHI 0024E 3.4)")

    # ----------------------------------------------------------------- per-cycle checks
    def _check_cycle(self, s, p):
        in_pu = 0
        for dd in range(N_PD):
            # power-aware checks
            iso, regs, rdy = s["iso_en"][dd], s["regs_iso"][dd], s["rdy_iso"][dd]
            if iso == 1:
                if regs != "0" * RB or rdy != 1:
                    self.err(f"PD{dd}: isolated outputs not clamped (bus={regs}, rdy_n={rdy})")
            elif iso == 0:
                if set(regs) - {"0", "1"} or rdy not in (0, 1):
                    self.err(f"PD{dd}: X/Z reaches AON with isolation released (bus={regs})")
            # safety properties at simulation level (formal proves them; this checks the env too)
            if s["ret_save"][dd] == 1 and not (iso == 1 and s["clk_en"][dd] == 0):
                self.err(f"PD{dd}: ret_save while not isolated or clock running (property 3)")
            if s["st"][dd] in (14, 15):
                in_pu += 1
            # property 4 at pin level: main enable rises only after DLY_TRICKLE cycles of trickle ack
            if p is not None:
                if p["psw_main_en"][dd] == 0 and s["psw_main_en"][dd] == 1:
                    if self.trk_hi[dd] < max(1, self.dly_trickle):
                        self.err(f"PD{dd}: main switch on after only {self.trk_hi[dd]} cycles of "
                                 f"trickle ack (DLY_TRICKLE {self.dly_trickle}; property 4)")
            self.trk_hi[dd] = self.trk_hi[dd] + 1 if s["psw_trickle_ack"][dd] == 1 else 0
            # Q-Channel controller rules (IHI 0068D 2.1.2) on the pins
            if p is not None and (s["rst_n"][dd] == 1 or p["rst_n"][dd] == 1):
                qr0, qr1 = p["QREQn"][dd], s["QREQn"][dd]
                qa, qd = p["QACCEPTn"][dd], p["QDENY"][dd]
                if qr0 == 1 and qr1 == 0 and not (qa == 1 and qd == 0):
                    self.err(f"PD{dd}: QREQn fell outside Q_RUN (QACCEPTn={qa}, QDENY={qd})")
                if qr0 == 0 and qr1 == 1 and qa != qd:
                    self.err(f"PD{dd}: QREQn rose with QACCEPTn={qa}, QDENY={qd}")
            if p is not None and p["rst_n"][dd] == 1 and s["rst_n"][dd] == 0:
                if not (p["QREQn"][dd] == 0 and p["QACCEPTn"][dd] == 0 and p["QDENY"][dd] == 0):
                    self.err(f"PD{dd}: device reset outside Q_STOPPED (IHI 0068D 2.1.2)")
            # event log for the sequence scoreboard
            if p is not None:
                for name in ("QREQn", "clk_en", "iso_en", "ret_save", "ret_restore", "rst_n",
                             "psw_trickle_en", "psw_main_en"):
                    if p[name][dd] != s[name][dd]:
                        self.events[dd].append((name, s[name][dd]))
                if p["st"][dd] not in STABLE and s["st"][dd] in STABLE | {4}:
                    self._sequence_done(dd, p, s)
                elif p["st"][dd] in STABLE and s["st"][dd] in STABLE and p["st"][dd] != s["st"][dd]:
                    self._sequence_done(dd, p, s)        # RET -> OFF bookkeeping
            if s["st"][dd] in STABLE and (p is None or p["st"][dd] not in STABLE):
                self.events[dd] = []
                if s["st"][dd] in STABLE:
                    self.last_stable[dd] = s["st"][dd]
        if in_pu > 1:
            self.err(f"inrush: {in_pu} domains in the power-up switching phase (property 5)")
        # domain shell contents at the moment isolation is released (power-up just completed)
        if p is not None:
            for dd in range(N_PD):
                if p["iso_en"][dd] == 1 and s["iso_en"][dd] == 0:
                    self._check_domain_contents(dd, s)
                if p["ret_save"][dd] == 0 and s["ret_save"][dd] == 1:
                    self.ret_saved[dd] = list(self.ret_written[dd])
                if s["ret_restore"][dd] == 1:
                    self.restored[dd] = True

    def _check_domain_contents(self, dd, s):
        regs = s["regs_iso"][dd]
        vals = [int(regs[RB - (i + 1) * W: RB - i * W], 2) for i in range(N_NORM + N_RET)]
        for i in range(N_NORM):
            exp = (0xA0 + 0x10 * dd + i) & 0xFF
            if vals[i] != exp:
                self.err(f"PD{dd}: normal reg {i} = {vals[i]:#x} after power-up, expected reset {exp:#x}")
        exp_ret = self.ret_saved[dd] if (HAS_RET[dd] and self.restored[dd]) else [0] * N_RET
        for i in range(N_RET):
            if vals[N_NORM + i] != exp_ret[i]:
                self.err(f"PD{dd}: retention reg {i} = {vals[N_NORM + i]:#x} after power-up, "
                         f"expected {exp_ret[i]:#x} ({'restored' if self.restored[dd] else 'reset'})")
        self.ret_written[dd] = list(exp_ret)
        self.restored[dd] = False
        if self.cov:
            self.cov.power_up(dd, bool(HAS_RET[dd] and exp_ret != [0] * N_RET))

    # ----------------------------------------------------------------- sequence scoreboard
    TEMPLATES = {
        "pd_ret":  [("QREQn", 0), ("clk_en", 0), ("iso_en", 1), ("ret_save", 1), ("ret_save", 0),
                    ("rst_n", 0), ("psw_main_en", 0), ("psw_trickle_en", 0)],
        "pd_off":  [("QREQn", 0), ("clk_en", 0), ("iso_en", 1), ("rst_n", 0), ("psw_main_en", 0),
                    ("psw_trickle_en", 0)],
        "cg_ret":  [("iso_en", 1), ("ret_save", 1), ("ret_save", 0), ("rst_n", 0), ("psw_main_en", 0),
                    ("psw_trickle_en", 0)],
        "cg_off":  [("iso_en", 1), ("rst_n", 0), ("psw_main_en", 0), ("psw_trickle_en", 0)],
        "cg_down": [("QREQn", 0), ("clk_en", 0)],
        "cg_up":   [("clk_en", 1), ("QREQn", 1)],
        "pu_rest": [("psw_trickle_en", 1), ("psw_main_en", 1), ("ret_restore", 1), ("ret_restore", 0),
                    ("rst_n", 1), ("clk_en", 1), ("iso_en", 0), ("QREQn", 1)],
        "pu":      [("psw_trickle_en", 1), ("psw_main_en", 1), ("rst_n", 1), ("clk_en", 1),
                    ("iso_en", 0), ("QREQn", 1)],
        "deny":    [("QREQn", 0), ("QREQn", 1)],
        "ret_off": [],
    }

    def _sequence_done(self, dd, p, s):
        frm, to = self.last_stable[dd], s["st"][dd]
        ev = self.events[dd]
        kind = None
        if to == 4:                                   # FAULT: no template; checked by the test
            kind = "fault"
        elif frm == 0 and to == 1:
            kind = "cg_down"
        elif frm == 0 and to == 0:
            kind = "deny"
        elif frm == 0 and to == 2:
            kind = "pd_ret"
        elif frm == 0 and to == 3:
            kind = "pd_off"
        elif frm == 1 and to == 0:
            kind = "cg_up"
        elif frm == 1 and to == 2:
            kind = "cg_ret"
        elif frm == 1 and to == 3:
            kind = "cg_off"
        elif frm in (2, 3) and to == 0:
            kind = "pu_rest" if any(e == ("ret_restore", 1) for e in ev) else "pu"
            if frm == 2 and HAS_RET[dd] and kind != "pu_rest":
                self.err(f"PD{dd}: power-up from RET without ret_restore")
        elif frm == 2 and to == 3:
            kind = "ret_off"
        elif frm == 4:
            kind = "fault_exit"
        if to == 4:
            self.after_fault[dd] = True
        elif kind in self.TEMPLATES:
            tpl = self.TEMPLATES[kind]
            if self.after_fault[dd]:
                # resumed after a FAULT: the events since the fault must be the rest of the template
                # (a power-switch fault goes straight to OFF, with no events)
                ok = ev == tpl[len(tpl) - len(ev):] if len(ev) <= len(tpl) else False
                kind = "fault_exit"
            else:
                ok = ev == tpl
            if not ok:
                self.err(f"PD{dd}: sequence {kind} ({frm}->{to}) out of order: {ev}")
            self.after_fault[dd] = False
        self.seq_checked += 1
        self.seq_log.append((dd, kind))
        if self.cov and kind:
            self.cov.sequence(dd, kind)
            if kind == "deny":
                tgt = MODE_TABLE[self.mode_req][dd]
                self.cov.deny(dd, {1: "CG", 2: "RET", 3: "OFF"}.get(tgt, "ON"))
        self.events[dd] = []
        if to in STABLE:
            self.last_stable[dd] = to

    # ----------------------------------------------------------------- driving the models
    def _drive(self, s):
        d = self.dut
        cfg, rng = self.cfg, self.rng
        qacc, qdeny, tack, mack = 0, 0, 0, 0
        wr_en, wr_idx, wr_data = 0, 0, 0
        for dd in range(N_PD):
            # --- power switches: ack follows enable after a random delay (or stuck, if injected)
            sw = self.sw[dd]
            for kind, en_name, key, wkey, on_f, off_f in (
                    ("trk", "psw_trickle_en", "trk", "t_wait", "trickle_on", "trickle_off"),
                    ("main", "psw_main_en", "main", "m_wait", "main_on", "main_off")):
                en = s[en_name][dd]
                if en in (0, 1) and en != sw[key]:
                    if self.fault.at(dd, on_f if en else off_f):
                        sw[wkey] = 0                     # stuck: never acknowledges
                    elif sw[wkey] <= 0:
                        sw[wkey] = rng.randint(*cfg.sw_lat)
                    else:
                        sw[wkey] -= 1
                        if sw[wkey] == 0:
                            sw[key] = en
                else:
                    sw[wkey] = 0
            tack |= sw["trk"] << dd
            mack |= sw["main"] << dd
            # --- Q-Channel device: acts only when powered, out of reset and clocked
            q = self.qdev_state[dd]
            powered = sw["trk"] and sw["main"]
            running = powered and s["rst_n"][dd] == 1 and s["clk_en"][dd] == 1
            if not powered or s["rst_n"][dd] != 1:
                q.update(acc=0, deny=0, wait=0, act=None)          # device reset: both LOW
            elif running:
                qr = s["QREQn"][dd]
                want = None
                if qr == 0 and q["acc"] == 1 and q["deny"] == 0:
                    may_deny = cfg.deny_doms is None or dd in cfg.deny_doms
                    want = "deny" if may_deny and rng.random() < cfg.deny_p else "accept"
                    where = "qaccept_down"
                elif qr == 1 and q["acc"] == 0 and q["deny"] == 0:
                    want, where = "exit", "qaccept_up"
                elif qr == 1 and q["acc"] == 1 and q["deny"] == 1:
                    want, where = "undeny", "qdeny_release"
                if want is None:
                    q["act"], q["wait"], q["sit"] = None, 0, None
                elif self.fault.at(dd, where):
                    q["act"], q["sit"] = None, None      # silent: no response while injected
                else:
                    if q.get("sit") != where:            # new situation: decide and pick a latency
                        q["sit"], q["act"], q["wait"] = where, want, rng.randint(*cfg.q_lat)
                    if q["act"] is not None:
                        if q["wait"] > 0:
                            q["wait"] -= 1
                        else:
                            if q["act"] == "accept":
                                q["acc"] = 0
                            elif q["act"] == "deny":
                                q["deny"] = 1
                            elif q["act"] == "exit":
                                q["acc"] = 1
                            elif q["act"] == "undeny":
                                q["deny"] = 0
                            q["act"] = None
            qacc |= q["acc"] << dd
            qdeny |= q["deny"] << dd
            # --- domain shell: random writes while the domain runs
            if running and s["iso_en"][dd] == 0 and rng.random() < cfg.write_p:
                idx = rng.randrange(N_NORM + N_RET)
                val = rng.randrange(256)
                wr_en |= 1 << dd
                wr_idx |= idx << (4 * dd)
                wr_data |= val << (W * dd)
                if idx >= N_NORM:
                    self.ret_written[dd][idx - N_NORM] = val
        d.psw_trickle_ack.value = tack
        d.psw_main_ack.value = mack
        d.QACCEPTn.value = qacc
        d.QDENY.value = qdeny
        d.dom_wr_en.value = wr_en
        d.dom_wr_idx.value = wr_idx
        d.dom_wr_data.value = wr_data

    # ----------------------------------------------------------------- helpers for tests
    def states(self):
        ps = str(self.dut.pmu_state.value)
        L = len(ps)
        return [int(ps[L - 7 * i - 5: L - 7 * i], 2) for i in range(N_PD)]

    async def wait_stable(self, timeout: int = 5000) -> bool:
        """Wait until no domain is in a sequence (all stable or FAULT) and MODE_STATUS is not busy."""
        for _ in range(timeout):
            await RisingEdge(self.dut.PCLK)
            await ReadOnly()
            st = self.states()
            if all(x in STABLE or x == 4 for x in st) and str(self.dut.pmu_state.value)[0] == "0":
                await RisingEdge(self.dut.PCLK)
                return True
        return False

    async def request(self, mode: str):
        """Write MODE_REQ without waiting for the transition."""
        err = await self.apb.wreg("MODE_REQ", MODES[mode])
        if err:
            self.err(f"MODE_REQ write {mode} returned PSLVERR")
        self.mode_req = mode

    async def set_mode(self, mode: str, timeout: int = 5000) -> bool:
        await self.request(mode)
        await RisingEdge(self.dut.PCLK)
        ok = await self.wait_stable(timeout)
        if not ok:
            self.err(f"mode {mode} not reached within {timeout} cycles; states {self.states()}")
        return ok

    def expect_states(self, before: list[int], mode: str) -> list[int]:
        """Expected stable states after a request with no deny/fault (SPEC 3.2 and 3.3)."""
        exp = []
        for dd, t in enumerate(MODE_TABLE[mode]):
            if t == ST["RET"] and not HAS_RET[dd]:
                t = ST["OFF"]
            exp.append(before[dd] if satisfies(before[dd], t) else t)
        return exp
