#!/usr/bin/env python3
"""Build results/summary.json: the only source of numbers for README, docs and resume (BRIEF rule 1).

Reads tool outputs only, and stores each value with its source path:
  flow/runs/<tag>/final/metrics.json   LibreLane run of the PMU (area, timing at every corner,
                                        power, DRC/LVS/antenna counts); copied to results/flow/
  results/verify_summary.json           verification roll-up (Phase 3)
  results/formal/liveness_bound.json    property 9 end-to-end bound
  results/sim/icarus_latency.json       measured mode entry/exit times
  results/power/breakeven.json          break-even analysis

    python3 scripts/parse_flow.py [--tag pmu_T20]
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def rel(p: Path) -> str:
    return str(p.relative_to(REPO))


def load(p: Path):
    return json.loads(p.read_text()) if p.exists() else None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tag", default="pmu_T20_nodly")
    a = ap.parse_args(argv)
    run = REPO / "flow" / "runs" / a.tag
    keep = REPO / "results" / "flow"
    keep.mkdir(parents=True, exist_ok=True)
    s = {"pdk": "sky130A / sky130_fd_sc_hd", "design": "pmu_top (always-on logic only)"}

    mfile = run / "final" / "metrics.json"
    if mfile.exists():
        shutil.copy(mfile, keep / "metrics.json")
        m = json.loads(mfile.read_text())
        cfg = load(run / "resolved.json") or {}
        corners = sorted(k.split("corner:")[1] for k in m if k.startswith("timing__setup__ws__corner:"))
        T = float(cfg.get("CLOCK_PERIOD", 0))
        s["flow"] = {
            "run": rel(run), "source": rel(keep / "metrics.json"), "clock_period_ns": T,
            "area": {"stdcell_count": m.get("design__instance__count__stdcell"),
                     "stdcell_area_um2": m.get("design__instance__area__stdcell"),
                     "core_area_um2": m.get("design__core__area"), "die_area_um2": m.get("design__die__area"),
                     "utilisation": m.get("design__instance__utilization__stdcell")},
            "timing": {c: {"setup_ws_ns": m.get(f"timing__setup__ws__corner:{c}"),
                           "setup_tns_ns": m.get(f"timing__setup__tns__corner:{c}"),
                           "hold_ws_ns": m.get(f"timing__hold__ws__corner:{c}"),
                           "hold_tns_ns": m.get(f"timing__hold__tns__corner:{c}"),
                           "fmax_MHz": round(1000.0 / (T - m[f"timing__setup__ws__corner:{c}"]), 2)
                           if T and m.get(f"timing__setup__ws__corner:{c}") is not None else None}
                       for c in corners},
            "power_W": {"total": m.get("power__total"), "internal": m.get("power__internal__total"),
                        "switching": m.get("power__switching__total"), "leakage": m.get("power__leakage__total"),
                        "label": "OpenSTA, LibreLane default activity (not annotated)"},
            "signoff": {"magic_drc_errors": m.get("magic__drc_error__count"),
                        "klayout_drc_errors": m.get("klayout__drc_error__count"),
                        "lvs_errors": m.get("design__lvs_error__count"),
                        "antenna_violating_nets": m.get("antenna__violating__nets"),
                        "route_drc_errors": m.get("route__drc_errors")},
        }
        ws = [v["setup_ws_ns"] for v in s["flow"]["timing"].values()]
        hs = [v["hold_ws_ns"] for v in s["flow"]["timing"].values()]
        s["flow"]["closes_all_corners"] = bool(ws and hs and min(ws) >= 0 and min(hs) >= 0)
        s["flow"]["worst_setup_ws_ns"], s["flow"]["worst_hold_ws_ns"] = min(ws), min(hs)
    else:
        s["flow"] = {"error": f"missing {rel(mfile)}"}

    for key, p in (("verification", REPO / "results" / "verify_summary.json"),
                   ("liveness_bound", REPO / "results" / "formal" / "liveness_bound.json"),
                   ("latency", REPO / "results" / "sim" / "icarus_latency.json")):
        d = load(p)
        s[key] = (d | {"source": rel(p)}) if d else {"error": f"missing {rel(p)}"}

    be = load(REPO / "results" / "power" / "breakeven.json")
    if be:
        s["breakeven"] = {"source": "results/power/breakeven.json", "assumptions": be["assumptions"],
                          "pmu_power_W": be["inputs"]["pmu_power_W"],
                          "breakeven_s": {c: {mm: v["breakeven_s"] for mm, v in r["modes"].items()}
                                          for c, r in be["results"].items()},
                          "P_run_idle_W": {c: r["P_run_idle_W"] for c, r in be["results"].items()},
                          "P_mode_W": {c: {mm: v["P_mode_W"] for mm, v in r["modes"].items()}
                                       for c, r in be["results"].items()},
                          "breakeven_vs_IDLE_s": {c: {mm: v.get("breakeven_vs_IDLE_s") for mm, v in r["modes"].items()
                                                      if mm != "IDLE"} for c, r in be["results"].items()},
                          "policy": be["policy"]}
    out = REPO / "results" / "summary.json"
    out.write_text(json.dumps(s, indent=2) + "\n")
    f = s.get("flow", {})
    print(f"flow: closes_all_corners={f.get('closes_all_corners')} worst setup {f.get('worst_setup_ws_ns')} "
          f"hold {f.get('worst_hold_ws_ns')} area {f.get('area', {}).get('stdcell_area_um2')} "
          f"power {f.get('power_W', {}).get('total')}")
    print(f"-> {rel(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
