#!/usr/bin/env python3
"""Check every ```wavedrom block in docs/*.md: valid JSON, all lanes the same length, and one
label per data cell. Exit 1 on any problem.

    python3 scripts/check_wavedrom.py
"""

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DATA_CELLS = "23456789="


def main() -> int:
    bad = 0
    for md in sorted((REPO / "docs").glob("*.md")):
        for i, blk in enumerate(re.findall(r"```wavedrom\n(.*?)```", md.read_text(), re.S), 1):
            where = f"{md.relative_to(REPO)} diagram {i}"
            try:
                lanes = [x for x in json.loads(blk)["signal"] if isinstance(x, dict) and "wave" in x]
            except (ValueError, KeyError) as e:
                print(f"{where}: invalid ({e})")
                bad += 1
                continue
            if len({len(x["wave"]) for x in lanes}) > 1:
                print(f"{where}: lanes differ in length: {[(x['name'], len(x['wave'])) for x in lanes]}")
                bad += 1
            for x in lanes:
                n = sum(c in DATA_CELLS for c in x["wave"])
                if "data" in x and n != len(x["data"]):
                    print(f"{where}: lane {x['name']} has {n} data cells but {len(x['data'])} labels")
                    bad += 1
            print(f"{where}: ok ({len(lanes)} lanes)") if not bad else None
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
