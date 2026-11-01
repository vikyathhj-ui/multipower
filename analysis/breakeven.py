#!/usr/bin/env python3
"""Break-even residency of each low-power mode (docs/BRIEF.md A4; explained in docs/POWER_ANALYSIS.md).

For a mode M entered from RUN (domains clocked but idle) and left again after a residency t:
    energy saved  E_saved(t) = (P_run_idle - P_M) * t - E_overhead(M)
    break-even    t_be(M)    = E_overhead(M) / (P_run_idle - P_M)
E_overhead is the energy spent by entering and leaving the mode (power switches, retention,
PMU activity). Computed at three liberty corners (TT, SS, FF).

Inputs (measured; never typed):
  * representative load: cell mix of LibreLane's `spm` example synthesised to sky130_fd_sc_hd
    (docs/DECISIONS.md D-014: the owner chose a representative netlist over the P1 ALU), scaled
    to an assumed size per domain;
  * cell leakage, flop clock-pin capacitance and the retention latch's leakage, from the sky130
    liberty at each corner;
  * entry and exit time of each mode, measured in simulation (tests/test_latency);
  * PMU power, from the post-route LibreLane run of the PMU (OpenSTA, default activity).
Assumptions: the named parameters in PARAMS below; each is listed in docs/POWER_ANALYSIS.md.

Run inside the iic-osic container from the repo root:
    python3 analysis/breakeven.py     # -> results/power/breakeven.json, results/plots/*.png
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LIBDIR = Path(os.environ.get("PDK_ROOT", "/foss/pdks")) / "sky130A" / "libs.ref" / "sky130_fd_sc_hd" / "lib"
CORNERS = {"TT": "tt_025C_1v80", "SS": "ss_100C_1v60", "FF": "ff_100C_1v95"}
VOLTS = {"TT": 1.80, "SS": 1.60, "FF": 1.95}

# ------------------------------------------------------------------------------ assumptions
# PMU energy per transition is an UPPER BOUND: the PMU's whole post-route power (OpenSTA, default
# activity) times the transition time. The PMU is always on and clocked in every mode, so most of
# that power is paid whether or not a transition happens; only the extra switching is overhead.
PARAMS = {
    "F_CLK_MHZ": 50.0,                 # domain and PMU clock (the PMU closes at 20 ns, flow/config.json)
    "N_CELLS": {"CPU": 20000, "DSP": 30000, "PERI": 10000},   # representative domain sizes (cells)
    "FLOP_FRACTION": 0.15,             # flops / cells in a domain (the spm mix is 1/3 flops: not CPU-like)
    "CLK_TREE_FACTOR": 2.0,            # clock-tree capacitance = factor x total flop clock-pin capacitance
    "N_RET_BITS": {"CPU": 1024, "DSP": 512, "PERI": 0},       # retained bits (PERI has no retention)
    "RET_LATCH_CELL": "sky130_fd_sc_hd__dlxtp_1",              # stand-in for a retention shadow latch
    "C_PER_CELL_FF": 5.0,              # switched capacitance per cell recharged at power-up (fF)
    "E_RET_PER_BIT_FJ": 20.0,          # save + restore energy per retained bit (fJ)
    "SWITCH_OFF_LEAK_FRACTION": 0.02,  # leakage left in a switched-off domain (switch off-current)
    "CLK_GATED_RESIDUAL": 0.0,         # clock power left in a gated domain (ICG alone is ignored)
}
# Domain states per mode (SPEC 3.2)
MODES = {"IDLE": {"CPU": "CG", "DSP": "CG", "PERI": "ON"},
         "SLEEP": {"CPU": "RET", "DSP": "RET", "PERI": "CG"},
         "DEEP_SLEEP": {"CPU": "RET", "DSP": "OFF", "PERI": "OFF"},
         "SHUTDOWN": {"CPU": "OFF", "DSP": "OFF", "PERI": "OFF"}}
LATENCY_JSON = REPO / "results" / "sim" / "icarus_latency.json"
PMU_METRICS = REPO / "results" / "flow" / "metrics.json"
OUT = REPO / "results" / "power" / "breakeven.json"


# ------------------------------------------------------------------------------ liberty
def liberty(corner: str) -> dict:
    """cell -> {'leak_nW': float, 'pins': {pin: cap_pF}} for one corner (plain-text .lib)."""
    text = (LIBDIR / f"sky130_fd_sc_hd__{CORNERS[corner]}.lib").read_text()
    unit = re.search(r'leakage_power_unit\s*:\s*"1(\w+)"', text).group(1)
    assert unit == "nW", unit
    cells = {}
    for m in re.finditer(r'\n    cell \("(\w+)"\) \{(.*?)\n    \}', text, re.S):
        body = m.group(2)
        leak = re.search(r"\n        cell_leakage_power\s*:\s*([\d.eE+-]+)", body)
        pins = {p.group(1): float(p.group(2)) for p in
                re.finditer(r'pin \("(\w+)"\) \{[^{}]*?\n\s+capacitance\s*:\s*([\d.eE+-]+)', body)}
        cells[m.group(1)] = {"leak_nW": float(leak.group(1)) if leak else 0.0, "pins": pins}
    return cells


def rep_cell_mix() -> dict:
    """Cell counts of the representative netlist (LibreLane's spm example, synthesised)."""
    out = REPO / "results" / "power" / "rep_cells.json"
    if out.exists():
        return json.loads(out.read_text())
    src = Path("/usr/local/lib/python3.12/dist-packages/librelane/examples/spm/src/spm.v")
    lib = LIBDIR / "sky130_fd_sc_hd__tt_025C_1v80.lib"
    work = REPO / "sim_build" / "rep"
    work.mkdir(parents=True, exist_ok=True)
    subprocess.run(["yosys", "-q", "-p", f"read_verilog {src}; synth -top spm -flatten; dfflibmap -liberty {lib}; "
                    f"abc -liberty {lib}; opt_clean; tee -q -o {work}/stat.json stat -json"], check=True)
    stat = json.loads((work / "stat.json").read_text())
    cells = stat["modules"]["\\spm"]["num_cells_by_type"]
    mix = {"design": "LibreLane example spm (serial-parallel multiplier), yosys synth + abc to sky130_fd_sc_hd",
           "cells": {k: v for k, v in cells.items() if k.startswith("sky130")}}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(mix, indent=2) + "\n")
    return mix


# ------------------------------------------------------------------------------ model
def corner_numbers(corner: str, mix: dict, lib: dict) -> dict:
    p = PARAMS
    n = sum(mix.values())
    avg_leak_nw = sum(lib[c]["leak_nW"] * k for c, k in mix.items()) / n
    flops = [c for c in mix if "df" in c]
    clk_pin_pf = sum(lib[c]["pins"].get("CLK", 0.0) * mix[c] for c in flops) / max(1, sum(mix[c] for c in flops))
    v, f = VOLTS[corner], p["F_CLK_MHZ"] * 1e6
    ret_leak_nw = lib[p["RET_LATCH_CELL"]]["leak_nW"]
    dom = {}
    for d, ncell in p["N_CELLS"].items():
        leak = ncell * avg_leak_nw * 1e-9                                   # W
        c_clk = ncell * p["FLOP_FRACTION"] * clk_pin_pf * 1e-12 * p["CLK_TREE_FACTOR"]
        clk = c_clk * v * v * f                                             # W (clock toggles once per cycle: C V^2 f)
        ret = p["N_RET_BITS"][d] * ret_leak_nw * 1e-9
        dom[d] = {"leak_W": leak, "clk_W": clk, "ret_leak_W": ret,
                  "state_power_W": {"ON": leak + clk,
                                    "CG": leak + p["CLK_GATED_RESIDUAL"] * clk,
                                    "RET": p["SWITCH_OFF_LEAK_FRACTION"] * leak + ret,
                                    "OFF": p["SWITCH_OFF_LEAK_FRACTION"] * leak},
                  "E_switch_J": ncell * p["C_PER_CELL_FF"] * 1e-15 * v * v,
                  "E_ret_J": p["N_RET_BITS"][d] * p["E_RET_PER_BIT_FJ"] * 1e-15}
    return {"avg_cell_leak_nW": avg_leak_nw, "flop_clk_pin_pF": clk_pin_pf, "ret_latch_leak_nW": ret_leak_nw,
            "domains": dom}


def analyse(corner: str, cn: dict, lat: dict, p_pmu_W: float) -> dict:
    T = 1.0 / (PARAMS["F_CLK_MHZ"] * 1e6)
    dom = cn["domains"]
    p_run = sum(d["state_power_W"]["ON"] for d in dom.values())
    out = {"P_run_idle_W": p_run, "modes": {}}
    for m, states in MODES.items():
        p_mode = sum(dom[d]["state_power_W"][s] for d, s in states.items())
        e_sw = sum(dom[d]["E_switch_J"] for d, s in states.items() if s in ("RET", "OFF"))
        e_ret = sum(dom[d]["E_ret_J"] for d, s in states.items() if s == "RET")
        cycles = lat["modes"][m]["entry_cycles"] + lat["modes"][m]["exit_cycles"]
        e_pmu = p_pmu_W * cycles * T
        e_over = e_sw + e_ret + e_pmu
        saving = p_run - p_mode
        out["modes"][m] = {"P_mode_W": p_mode, "saving_W": saving,
                           "E_overhead_J": e_over, "E_switch_J": e_sw, "E_retention_J": e_ret, "E_pmu_J": e_pmu,
                           "transition_cycles": cycles, "exit_latency_s": lat["modes"][m]["exit_cycles"] * T,
                           "breakeven_s": e_over / saving if saving > 0 else None}
    # deeper modes against IDLE: is the extra overhead worth it once the clocks are gated anyway?
    idle = out["modes"]["IDLE"]
    for m, v in out["modes"].items():
        if m == "IDLE":
            continue
        dp = idle["P_mode_W"] - v["P_mode_W"]
        de = v["E_overhead_J"] - idle["E_overhead_J"]
        v["breakeven_vs_IDLE_s"] = de / dp if dp > 0 else None
    return out


def policy(res: dict) -> list:
    """Best mode by expected residency t (max energy saved) for one corner: the crossover points
    between consecutive best modes on a log grid (20 points per decade)."""
    modes = res["modes"]
    grid = [10 ** (e / 20) for e in range(-140, 41)]                   # 1e-7 s .. 1e2 s
    best_prev, segs = None, []
    for t in grid:
        cand = [(v["saving_W"] * t - v["E_overhead_J"], m) for m, v in modes.items()]
        e, m = max(cand)
        best = m if e > 0 else "RUN (stay)"
        if best != best_prev:
            segs.append({"from_s": t, "mode": best})
            best_prev = best
    return segs


def plot(results: dict, path: Path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    colors = {"IDLE": "#2a78d6", "SLEEP": "#eb6834", "DEEP_SLEEP": "#1baf7a", "SHUTDOWN": "#6250d6"}
    fig, axes = plt.subplots(2, 3, figsize=(13, 7.6))
    top = [10 ** (e / 40) * 1e-7 for e in range(0, 121)]               # 100 ns .. 100 us
    bot = [10 ** (e / 30) * 1e-6 for e in range(0, 181)]               # 1 us .. 1 s
    for col, (corner, res) in enumerate(results.items()):
        ax = axes[0][col]
        for m, v in res["modes"].items():
            ax.plot(top, [(v["saving_W"] * t - v["E_overhead_J"]) * 1e9 for t in top], color=colors[m], lw=2, label=m)
            if v["breakeven_s"]:
                ax.plot([v["breakeven_s"]], [0], marker="o", color=colors[m], ms=6, mec="white", mew=1.5)
        ax.set_title(f"{corner} ({CORNERS[corner]}): vs staying in RUN", loc="left", fontsize=9)
        ax.set_yscale("symlog", linthresh=1.0)
        ax = axes[1][col]
        idle = res["modes"]["IDLE"]
        for m, v in res["modes"].items():
            if m == "IDLE":
                continue
            dp, de = idle["P_mode_W"] - v["P_mode_W"], v["E_overhead_J"] - idle["E_overhead_J"]
            ax.plot(bot, [(dp * t - de) * 1e9 for t in bot], color=colors[m], lw=2, label=m)
            if v.get("breakeven_vs_IDLE_s"):
                ax.plot([v["breakeven_vs_IDLE_s"]], [0], marker="o", color=colors[m], ms=6, mec="white", mew=1.5)
        ax.set_title(f"{corner}: deeper modes vs IDLE", loc="left", fontsize=9)
        ax.set_yscale("symlog", linthresh=1.0)
        for ax in (axes[0][col], axes[1][col]):
            ax.axhline(0, color="#52514e", lw=0.8)
            ax.set_xscale("log")
            ax.set_xlabel("residency in the mode (s)")
            ax.grid(True, color="#e4e3df", lw=0.6)
            for sp in ("top", "right"):
                ax.spines[sp].set_visible(False)
    axes[0][0].set_ylabel("energy saved (nJ)")
    axes[1][0].set_ylabel("extra energy saved vs IDLE (nJ)")
    axes[0][0].legend(frameon=False, fontsize=8)
    axes[1][0].legend(frameon=False, fontsize=8)
    fig.suptitle("Break-even residency (dots). Representative load; every assumption is a named parameter "
                 "(analysis/breakeven.py PARAMS)", x=0.01, ha="left", fontsize=10)
    fig.tight_layout()
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=150)
    fig.savefig(path.with_suffix(".svg"))


def math_log10(x):
    import math
    return math.log10(x)


def main() -> int:
    mix = rep_cell_mix()
    lat = json.loads(LATENCY_JSON.read_text())
    m = json.loads(PMU_METRICS.read_text())
    p_pmu = m["power__total"]                                         # W, OpenSTA, default activity
    results, corner_data = {}, {}
    for corner in CORNERS:
        lib = liberty(corner)
        cn = corner_numbers(corner, mix["cells"], lib)
        corner_data[corner] = cn
        results[corner] = analyse(corner, cn, lat, p_pmu)
    out = {"assumptions": PARAMS, "modes": MODES, "corners": CORNERS,
           "inputs": {"representative_netlist": str((REPO / "results" / "power" / "rep_cells.json").relative_to(REPO)),
                      "latency": str(LATENCY_JSON.relative_to(REPO)),
                      "pmu_power_W": p_pmu, "pmu_power_source": str(PMU_METRICS.relative_to(REPO)) + " power__total",
                      "pmu_power_label": "OpenSTA, LibreLane default activity (not annotated)"},
           "corner_data": corner_data, "results": results,
           "policy": {c: policy(r) for c, r in results.items()}}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, indent=2) + "\n")
    plot(results, REPO / "results" / "plots" / "breakeven.png")
    for c, r in results.items():
        print(c, {k: (f"{v['breakeven_s']:.3g} s" if v["breakeven_s"] else "never") for k, v in r["modes"].items()},
              "vs IDLE:", {k: (f"{v['breakeven_vs_IDLE_s']:.3g} s" if v.get("breakeven_vs_IDLE_s") else "-")
                           for k, v in r["modes"].items() if k != "IDLE"})
    for c, pol in out["policy"].items():
        print(f"policy ({c}):", [(f"{s['from_s']:.3g}", s["mode"]) for s in pol])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
