"""Functional coverage for the PMU testbench (docs/BRIEF.md A3), built on cocotb-coverage.

Coverage points (bins that the specification makes impossible are left out and listed in IGNORED
with the reason; docs/VERIFICATION.md explains them):
  transition   (from mode, to mode)            the 5x5 mode matrix
  dom_seq      (domain, sequence kind)          per-domain state x event
  deny_loc     (domain, target)                 where a quiescence request was denied
  fault_loc    (domain, FAULT_INFO.STEP name)   where a wait step timed out
  reg_access   (register, read/write, ok/err)   the register-access matrix
  power_up     (domain, restored)               power-up with and without a retention restore
"""

from __future__ import annotations

import json
from pathlib import Path

from cocotb_coverage.coverage import CoverPoint, coverage_db

import regmap as rm

MODES = list(rm.MODE)                                   # RUN, IDLE, SLEEP, DEEP_SLEEP, SHUTDOWN
HAS_RET = [1, 1, 0]
SEQ_KINDS = ["pd_ret", "pd_off", "cg_down", "cg_up", "cg_ret", "cg_off", "pu_rest", "pu", "deny",
             "ret_off", "fault", "fault_exit"]
RET_KINDS = {"pd_ret", "cg_ret", "pu_rest", "ret_off"}
FAULT_STEPS = list(rm.FAULT_STEP)                       # QACCEPT_DOWN ... QACCEPT_UP
TARGETS = ["CG", "RET", "OFF"]
ADDR_NAME = {r["addr"]: n for n, r in rm.REGS.items()}

IGNORED: dict[str, list[dict]] = {"dom_seq": [], "deny_loc": [], "reg_access": [], "power_up": []}


def _dom_seq_bins():
    bins = []
    for d in range(rm.N_PD):
        for k in SEQ_KINDS:
            if k in RET_KINDS and not HAS_RET[d]:
                IGNORED["dom_seq"].append({"bin": [d, k], "reason": "PD_PERI has no retention (BRIEF A2)"})
            else:
                bins.append((d, k))
    return bins


def _deny_bins():
    bins = []
    for d in range(rm.N_PD):
        for t in TARGETS:
            if t == "RET" and not HAS_RET[d]:
                IGNORED["deny_loc"].append({"bin": [d, t], "reason": "no mode puts PD_PERI in RET"})
            else:
                bins.append((d, t))
    return bins


def _reg_bins():
    bins = []
    for name, r in rm.REGS.items():
        bins.append((name, "read", "ok"))
        if r["access"] == "RO":
            bins.append((name, "write", "err"))
            IGNORED["reg_access"].append({"bin": [name, "write", "ok"], "reason": "read-only register"})
        else:
            bins.append((name, "write", "ok"))
            if name in ("MODE_REQ", "WAKE_MODE"):
                bins.append((name, "write", "err"))      # illegal mode value
    bins += [("UNMAPPED", "read", "err"), ("UNMAPPED", "write", "err")]
    return bins


def _pu_bins():
    bins = []
    for d in range(rm.N_PD):
        bins.append((d, False))
        if HAS_RET[d]:
            bins.append((d, True))
        else:
            IGNORED["power_up"].append({"bin": [d, True], "reason": "PD_PERI has no retention"})
    return bins


DOM_SEQ_BINS, DENY_BINS, REG_BINS, PU_BINS = _dom_seq_bins(), _deny_bins(), _reg_bins(), _pu_bins()


@CoverPoint("pmu.transition", xf=lambda a, b: (a, b), bins=[(a, b) for a in MODES for b in MODES])
def _transition(a, b):
    pass


@CoverPoint("pmu.dom_seq", xf=lambda d, k: (d, k), bins=DOM_SEQ_BINS)
def _dom_seq(d, k):
    pass


@CoverPoint("pmu.deny_loc", xf=lambda d, t: (d, t), bins=DENY_BINS)
def _deny(d, t):
    pass


@CoverPoint("pmu.fault_loc", xf=lambda d, s: (d, s), bins=[(d, s) for d in range(rm.N_PD) for s in FAULT_STEPS])
def _fault(d, s):
    pass


@CoverPoint("pmu.reg_access", xf=lambda n, rw, res: (n, rw, res), bins=REG_BINS)
def _reg(n, rw, res):
    pass


@CoverPoint("pmu.power_up", xf=lambda d, r: (d, r), bins=PU_BINS)
def _pu(d, r):
    pass


class Coverage:
    """Sampling interface used by tb/pmu_env.py and the tests."""

    def transition(self, frm: str, to: str):
        _transition(frm, to)

    def sequence(self, d: int, kind: str):
        _dom_seq(d, kind)

    def deny(self, d: int, target: str):
        _deny(d, target)

    def fault(self, d: int, step_code: int):
        name = next((k for k, v in rm.FAULT_STEP.items() if v == step_code), None)
        if name:
            _fault(d, name)

    def reg_access(self, addr: int, write: bool, err: int):
        _reg(ADDR_NAME.get(addr & 0xFFC, "UNMAPPED"), "write" if write else "read", "err" if err else "ok")

    def power_up(self, d: int, restored: bool):
        _pu(d, restored)


POINTS = ["transition", "dom_seq", "deny_loc", "fault_loc", "reg_access", "power_up"]


def report(path: Path) -> dict:
    points = {}
    for name in POINTS:
        cp = coverage_db[f"pmu.{name}"]
        missed = [list(k) if isinstance(k, tuple) else k for k, h in cp.detailed_coverage.items() if h == 0]
        points[name] = {"bins": cp.size, "covered": cp.coverage,
                        "percent": round(100.0 * cp.coverage / cp.size, 2) if cp.size else 100.0,
                        "missed": missed, "ignored": IGNORED.get(name, [])}
    tb, tc = sum(p["bins"] for p in points.values()), sum(p["covered"] for p in points.values())
    summary = {"bins": tb, "covered": tc, "percent": round(100.0 * tc / tb, 2), "points": points}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, indent=2) + "\n")
    return summary
