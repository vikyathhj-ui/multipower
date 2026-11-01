#!/usr/bin/env python3
"""Roll up the verification results into results/verify_summary.json (BRIEF Phase 3 gate).

Reads only result files, each recorded with its path:
  results/lint_summary.txt          scripts/lint.sh
  results/sim/icarus.xml            scripts/run_sim.py (cocotb JUnit)
  sim_build/cocotb/icarus/sim.log   per-test summary lines ("PASS test_x: N sequences checked ...")
  results/coverage/icarus.json      tb/pmu_coverage.py
  results/formal/summary.json       scripts/run_formal.py
  results/mutation.json             scripts/mutate.py

    python3 scripts/verify_summary.py
"""

from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "results" / "verify_summary.json"


def rel(p: Path) -> str:
    return str(p.relative_to(REPO))


def main() -> int:
    problems, checks = [], {}

    lint = REPO / "results" / "lint_summary.txt"
    if lint.exists():
        t = lint.read_text()
        checks["lint"] = {"result": "PASS" if "RESULT: PASS" in t else "FAIL",
                          "configs": len(re.findall(r"^PASS  verilator", t, re.M)), "source": rel(lint)}
    else:
        problems.append("missing results/lint_summary.txt")

    xml = REPO / "results" / "sim" / "icarus.xml"
    log = REPO / "sim_build" / "cocotb" / "icarus" / "sim.log"
    if xml.exists():
        cases = list(ET.parse(xml).getroot().iter("testcase"))
        failed = [c.get("name") for c in cases if c.find("failure") is not None or c.find("error") is not None]
        tests = {}
        if log.exists():
            for m in re.finditer(r"(PASS|FAIL) (test_\w+): (\d+) sequences checked, (\d+) errors(?: \((.*?)\))?",
                                 log.read_text(errors="replace")):
                tests[m.group(2)] = {"status": m.group(1), "sequences_checked": int(m.group(3)),
                                     "errors": int(m.group(4)), "detail": m.group(5)}
        soak = tests.get("test_soak", {}).get("detail") or ""
        m = re.search(r"(\d+) requests", soak)
        checks["simulation"] = {"result": "PASS" if not failed and cases else "FAIL", "tests": len(cases),
                                "failed": failed, "per_test": tests,
                                "soak_requests": int(m.group(1)) if m else None,
                                "sequences_checked": sum(t["sequences_checked"] for t in tests.values()),
                                "source": rel(xml)}
    else:
        problems.append("missing results/sim/icarus.xml")

    cov = REPO / "results" / "coverage" / "icarus.json"
    if cov.exists():
        c = json.loads(cov.read_text())
        checks["coverage"] = {"percent": c["percent"], "bins": c["bins"], "covered": c["covered"],
                              "missed": {k: v["missed"] for k, v in c["points"].items() if v["missed"]},
                              "source": rel(cov)}
    else:
        problems.append("missing results/coverage/icarus.json")

    formal = REPO / "results" / "formal" / "summary.json"
    if formal.exists():
        f = json.loads(formal.read_text())
        cov_task = next((t for t in f["tasks"] if t["task"] == "cover"), {})
        checks["formal"] = {"result": f["result"], "proofs": f.get("proofs"), "covers": f.get("covers"),
                            "covers_reached": cov_task.get("reached"),
                            "tasks": {t["task"]: t["status"] for t in f["tasks"]}, "source": rel(formal)}
    else:
        problems.append("missing results/formal/summary.json")

    mut = REPO / "results" / "mutation.json"
    if mut.exists():
        m = json.loads(mut.read_text())
        checks["mutation"] = {"result": m["result"], "mutants": len(m["mutants"]),
                              "missed": [x["mutant"] for x in m["mutants"]
                                         if "caught" not in x["sim"] and "caught" not in x.get("formal", "")],
                              "source": rel(mut)}
    else:
        problems.append("missing results/mutation.json")

    ok = (not problems and checks["lint"]["result"] == "PASS" and checks["simulation"]["result"] == "PASS"
          and checks["coverage"]["percent"] == 100.0 and checks["formal"]["proofs"] == "PASS"
          and checks["mutation"]["result"] == "PASS")
    open_items = []
    if checks.get("formal", {}).get("covers") not in (None, "PASS"):
        open_items.append(f"formal covers: {checks['formal']['covers']} "
                          f"({checks['formal']['covers_reached']} reached; see {checks['formal']['source']})")
    result = "FAIL" if not ok else ("PASS" if not open_items else "PASS with open items")
    summary = {"result": result, "open_items": open_items, "problems": problems, "checks": checks}
    OUT.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"result": summary["result"], "problems": problems,
                      **{k: v.get("result", v.get("percent")) for k, v in checks.items()}}, indent=1))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
