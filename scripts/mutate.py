#!/usr/bin/env python3
"""Mutation check of the verification (docs/VERIFICATION.md): each mutant inserts one deliberate
bug into a copy of rtl/ (sim_build/mut/<name>/), then the cocotb suite (and, for mutants marked
formal, the k-induction proof) must FAIL. A mutant that passes means a check is missing.

    .venv/bin/python scripts/mutate.py [--only NAME] [--soak 100]
Output: results/mutation.json
"""

from __future__ import annotations

import argparse
import xml.etree.ElementTree as ET
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# name: (file, original text, mutated text, also run formal?, what it breaks)
MUTANTS = {
    # control: no change; the suite and the proof must PASS, otherwise the harness is broken
    "control":           ("rtl/pd_ctrl.sv", "", "", True, "none (harness check)"),
    "iso_release_early": ("rtl/pd_ctrl.sv", "clk_en <= 1'b1;                     // step 7",
                          "clk_en <= 1'b1; iso_en <= 1'b0;", True,
                          "isolation released before the clock runs (power-up order)"),
    "no_ret_save":       ("rtl/pd_ctrl.sv", "ret_save <= 1'b1;               // step 5",
                          "ret_save <= 1'b0;", False, "retention state not saved"),
    "no_restore":        ("rtl/pd_ctrl.sv", "if (HAS_RET && ret_valid) begin", "if (1'b0) begin", False,
                          "retention not restored on power-up"),
    "arb_no_hold":       ("rtl/inrush_arb.sv", "else if (|(gnt & req))      gnt <= gnt;",
                          "else if (1'b0)              gnt <= gnt;", True,
                          "arbiter re-grants every cycle (inrush)"),
    "qreq_rule":         ("rtl/qch_master.sv", "if (qacceptn && qdeny)               qreqn <= 1'b1;",
                          "if (qacceptn)                        qreqn <= 1'b1;", True,
                          "QREQn rises from Q_REQUEST (Q-Channel rule)"),
    "trickle_first_off": ("rtl/pd_ctrl.sv", "psw_main_en <= 1'b0;                // step 7a: main first",
                          "psw_trickle_en <= 1'b0;", False, "trickle switch turned off before main"),
    "no_settle":         ("rtl/pd_ctrl.sv", "assign settled = (cnt >= 17'(SYNC_STAGES));",
                          "assign settled = 1'b1;", True, "regression of formal bug F-001 (stale ack)"),
    "err_write_takes":   ("rtl/apb_regs.sv", "assign we      = wr && !err;", "assign we      = wr;", True,
                          "an erroring APB write changes a register"),
    "no_psw_timeout":    ("rtl/pd_ctrl.sv", "assign to_psw = wait_psw && (cnt1 >= tmo(tmo_psw));",
                          "assign to_psw = 1'b0;", False, "switch timeouts never fire"),
    "deny_ignored":      ("rtl/pd_ctrl.sv", "end else if (q_deny) begin", "end else if (1'b0) begin", False,
                          "a deny is not handled"),
    "wake_mask_inverted": ("rtl/wake_ctrl.sv", "~wake_mask", "wake_mask", False, "wake mask polarity"),
}


def run(cmd, cwd, env=None, timeout=3600) -> int:
    return subprocess.run(cmd, cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
                          timeout=timeout).returncode


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--only", action="append")
    ap.add_argument("--soak", type=int, default=100)
    a = ap.parse_args(argv)
    results = []
    for name, (f, old, new, formal, what) in MUTANTS.items():
        if a.only and name not in a.only:
            continue
        root = REPO / "sim_build" / "mut" / name
        if root.exists():
            shutil.rmtree(root)
        for sub in ("rtl", "tb", "scripts", "formal"):
            # skip only SymbiYosys task directories (formal/pmu_<task>/) and caches
            skip = (lambda d, names: [n for n in names if n == "__pycache__" or
                                      (Path(d).name == "formal" and (Path(d) / n).is_dir())])
            shutil.copytree(REPO / sub, root / sub, ignore=skip)
        if old:
            src = (root / f).read_text()
            assert src.count(old) == 1, f"{name}: pattern not found exactly once in {f}"
            (root / f).write_text(src.replace(old, new))
        (root / ".venv").symlink_to(REPO / ".venv")
        env = dict(os.environ)
        run([str(REPO / ".venv" / "bin" / "python"), "scripts/run_sim.py", "--soak", str(a.soak),
             "--name", "mut"], cwd=root, env=env)
        # a mutant counts as caught only if the tests ran and a test failed on a check
        xml = root / "results" / "sim" / "mut.xml"
        cases = list(ET.parse(xml).getroot().iter("testcase")) if xml.exists() else []
        n_fail = sum(c.find("failure") is not None or c.find("error") is not None for c in cases)
        ran = len(cases) >= 9 and not any("ModuleNotFoundError" in (c.findtext("failure") or "") +
                                           (c.findtext("error") or "") for c in cases)
        sim = ("ERROR (suite did not run)" if not ran else
               "FAIL (caught)" if n_fail else "PASS (missed)")
        rec = {"mutant": name, "file": f, "breaks": what, "sim": sim, "tests_failed": n_fail}
        if formal:
            fr = run(["sby", "-f", "pmu.sby", "prove"], cwd=root / "formal")
            rec["formal"] = "FAIL (caught)" if fr else "PASS (missed)"
        log = root / "sim_build" / "cocotb" / "mut" / "sim.log"
        if log.exists():
            first = next((l.strip() for l in log.read_text(errors="replace").splitlines() if " ERROR " in l), "")
            rec["first_error"] = re.sub(r"\s+", " ", first)[:200]
        print(json.dumps(rec), flush=True)
        results.append(rec)
    ctrl = next((r for r in results if r["mutant"] == "control"), None)
    harness_ok = ctrl is None or (ctrl["sim"] == "PASS (missed)" and ctrl.get("formal") == "PASS (missed)")
    if ctrl:
        ctrl["sim"] = ctrl["sim"].replace(" (missed)", " (expected)")
        if "formal" in ctrl:
            ctrl["formal"] = ctrl["formal"].replace(" (missed)", " (expected)")
    caught = harness_ok and all(r["mutant"] == "control" or "caught" in r["sim"] or
                                "caught" in r.get("formal", "") for r in results)
    out = REPO / "results" / "mutation.json"
    out.write_text(json.dumps({"result": "PASS" if caught else "FAIL", "mutants": results}, indent=2) + "\n")
    print(f"-> {out.relative_to(REPO)}: {'every mutant caught' if caught else 'SOME MUTANTS MISSED'}")
    return 0 if caught else 1


if __name__ == "__main__":
    sys.exit(main())
