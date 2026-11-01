#!/usr/bin/env python3
"""End-to-end bounded-liveness bound (property 9) from the proven per-state bounds.

The `live` formal task proves, for the reset configuration, that each transient state is left
within its bound, that an armed off-target stable state is left in the next cycle, and that a free
inrush grant goes to the lowest-index requester in one cycle. This script adds those bounds along
the longest path a request can take for one domain (no deny, no fault, no new request meanwhile):

  finish an in-progress power-down to OFF  ->  arbiter wait (the other domains' switching phases)
  ->  power-up to ON  ->  clock-gate (target CLK_GATED)

Delays and timeouts come from scripts/regmap.yaml reset values. Output: results/formal/liveness_bound.json

    python3 scripts/liveness_bound.py
"""

from __future__ import annotations

import json
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parent.parent


def main() -> int:
    m = yaml.safe_load((REPO / "scripts" / "regmap.yaml").read_text())
    rst = {r["name"]: r["fields"][0]["reset"] for r in m["registers"]}
    dly = lambda n: max(1, rst[n])                                   # noqa: E731 (0 means 1)
    tq, tp = rst["TMO_QCH"] or 65536, rst["TMO_PSW"] or 65536
    n_pd = m["n_pd"]
    # per-state bounds, as proven in formal/pmu_props.sv (g_live.p9a_*)
    b = {"D_QWAIT": tq, "D_CLK": dly("DLY_CLK"), "D_ISO": dly("DLY_ISO"), "D_SAVE": dly("DLY_RET"),
         "D_RST": dly("DLY_RST"), "D_MAIN_OFF": tp, "D_TRK_OFF": tp,
         "U_TRK_ON": tp + dly("DLY_TRICKLE"), "U_MAIN_ON": tp + dly("DLY_MAIN"),
         "U_RESTORE": dly("DLY_RET"), "U_RST": dly("DLY_RST"), "U_CLK": dly("DLY_CLK"), "U_ISO": 1,
         "U_QEXIT": tq, "stable": 1}
    down = ["D_QWAIT", "D_CLK", "D_ISO", "D_SAVE", "D_RST", "D_MAIN_OFF", "D_TRK_OFF"]
    up = ["U_TRK_ON", "U_MAIN_ON", "U_RESTORE", "U_RST", "U_CLK", "U_ISO", "U_QEXIT"]
    cg_down = ["stable", "D_QWAIT", "D_CLK"]
    phase = b["U_TRK_ON"] + b["U_MAIN_ON"]                           # one domain's switching phase
    arb = (n_pd - 1) * (phase + 1) + 1                               # others first, then 1-cycle grant
    parts = {"power_down": sum(b[s] for s in down), "stable_exit": b["stable"], "arbiter_wait": arb,
             "power_up": sum(b[s] for s in up), "clock_gate": sum(b[s] for s in cg_down)}
    total = sum(parts.values())
    out = {"bound_cycles": total, "parts": parts, "per_state": b,
           "assumptions": ["configuration at reset values (DLY_*/TMO_* not written)", "no deny, no fault",
                           "no new MODE_REQ or wake event while the request is in progress",
                           "per-state bounds proven by `sby -f formal/pmu.sby live`"],
           "source": "scripts/liveness_bound.py from scripts/regmap.yaml reset values"}
    p = REPO / "results" / "formal" / "liveness_bound.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(out, indent=2) + "\n")
    print(f"bound {total} cycles: {parts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
