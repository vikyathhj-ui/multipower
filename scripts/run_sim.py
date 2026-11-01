#!/usr/bin/env python3
"""Build and run the cocotb testbench (tb/) on Icarus.

    .venv/bin/python scripts/run_sim.py [--test NAME ...] [--seed N]

Results: results/sim/<name>.xml (cocotb JUnit) and the log in sim_build/cocotb/.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tb"))
os.environ["PYTHONPATH"] = os.pathsep.join([str(REPO / "tb"), os.environ.get("PYTHONPATH", "")])

from cocotb_tools.runner import get_runner  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--test", action="append", help="test function(s); default all")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--name", default="icarus")
    ap.add_argument("--soak", type=int, default=10000, help="soak-test requests")
    a = ap.parse_args(argv)
    rtl = [REPO / f for f in (REPO / "scripts" / "rtl_files.txt").read_text().split()]
    srcs = rtl + [REPO / "tb" / "domain_shell.sv", REPO / "tb" / "tb_top.sv"]
    build = REPO / "sim_build" / "cocotb" / a.name
    runner = get_runner("icarus")
    runner.build(sources=srcs, hdl_toplevel="tb_top", build_dir=build, always=True,
                 timescale=("1ns", "1ps"), build_args=["-g2012"], log_file=build / "build.log")
    out = REPO / "results" / "sim"
    out.mkdir(parents=True, exist_ok=True)
    xml = out / f"{a.name}.xml"
    runner.test(test_module="test_pmu", hdl_toplevel="tb_top", build_dir=build, test_dir=build,
                testcase=a.test, extra_env={"PMU_SEED": str(a.seed), "PMU_SOAK": str(a.soak),
                           "PMU_COV_OUT": str(REPO / "results" / "coverage" / f"{a.name}.json")}, results_xml=xml,
                log_file=build / "sim.log", timescale=("1ns", "1ps"))
    import xml.etree.ElementTree as ET
    cases = list(ET.parse(xml).getroot().iter("testcase"))
    bad = [c.get("name") for c in cases if c.find("failure") is not None or c.find("error") is not None]
    print(f"{len(cases) - len(bad)}/{len(cases)} tests passed{': FAILED ' + ', '.join(bad) if bad else ''}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
