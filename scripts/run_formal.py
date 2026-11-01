#!/usr/bin/env python3
"""Run the SymbiYosys tasks in formal/pmu.sby and write results/formal/summary.json.

Tasks: prove (properties 1-8, k-induction), live (property 9, k-induction, reset config),
cover (the brief's covers). Results are read from SBY's own status and log files.

Run inside the iic-osic container from the repo root:
    python3 scripts/run_formal.py [--task prove --task live --task cover] [--no-run]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FORMAL = REPO / "formal"
OUT = REPO / "results" / "formal" / "summary.json"
TASKS = ["prove", "live", "cover"]


def run(task: str) -> float:
    t0 = time.time()
    subprocess.run(["sby", "-f", "pmu.sby", task], cwd=FORMAL, stdout=subprocess.DEVNULL,
                   stderr=subprocess.STDOUT)
    return round(time.time() - t0, 1)


def parse(task: str) -> dict:
    d = FORMAL / f"pmu_{task}"
    status = (d / "status").read_text().split()[0] if (d / "status").exists() else "MISSING"
    log = (d / "logfile.txt").read_text(errors="replace") if (d / "logfile.txt").exists() else ""
    rec = {"task": task, "status": status, "source": str((d / "logfile.txt").relative_to(REPO))}
    if task in ("prove", "live"):
        m = re.search(r"summary: (successful proof by k-induction)", log)
        rec["method"] = m.group(1) if m else None
        rec["failed"] = sorted(set(re.findall(r"failed assertion (\S+)", log)))
        # property names checked: every labelled assert in the elaborated design
        rec["asserts"] = len(re.findall(r"\$assert|\$check", (d / "model" / "design.log").read_text(errors="replace"))) \
            if (d / "model" / "design.log").exists() else None
    else:
        reached = sorted(set(re.findall(r"Reached cover statement (?:in pmu_top )?at (\S+)", log)))
        unreached = sorted(set(re.findall(r"Unreached cover statement (?:in pmu_top )?at (\S+)", log)))
        rec.update({"reached": len(reached), "unreached": unreached,
                    "reached_list": reached})
    m = re.search(r"Elapsed clock time \[H:MM:SS \(secs\)\]: \S+ \((\d+)\)", log)
    rec["seconds"] = int(m.group(1)) if m else None
    return rec


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--task", action="append", choices=TASKS)
    ap.add_argument("--no-run", action="store_true", help="only collect existing results")
    a = ap.parse_args(argv)
    tasks = a.task or TASKS
    if not a.no_run:
        for t in tasks:
            print(f"sby {t} ...", flush=True)
            run(t)
    recs = [parse(t) for t in TASKS if (FORMAL / f"pmu_{t}").exists()]
    ok = all(r["status"] == "PASS" for r in recs) and len(recs) == len(TASKS)
    summary = {"result": "PASS" if ok else "FAIL", "tool": "SymbiYosys + yices (smtbmc)", "tasks": recs}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(summary, indent=2) + "\n")
    for r in recs:
        extra = r.get("method") or (f"{r.get('reached')} reached, unreached {r.get('unreached')}"
                                    if r["task"] == "cover" else "")
        print(f"{r['task']:<6} {r['status']:<8} {extra} ({r.get('seconds')} s)")
    print(f"-> {OUT.relative_to(REPO)}: {summary['result']}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
