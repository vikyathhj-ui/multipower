#!/usr/bin/env python3
"""Print selected signals of a SymbiYosys counterexample VCD as a step-by-step table.

    python3 scripts/cex_table.py formal/pmu_prove/engine_0/trace.vcd PRESETn psw_main_ack 'u_pd.st'

Each pattern is matched against the end of the full hierarchical signal name; every match is
shown (so 'u_pd.st' shows the state of every domain), in the order the patterns are given.
Values are printed in hex, one row per VCD time step (two per clock cycle).
"""

from __future__ import annotations

import sys


def parse(path: str):
    ids, scope, names = {}, [], {}
    changes, t = {}, None
    with open(path) as f:
        for line in f:
            w = line.split()
            if not w:
                continue
            if w[0] == "$scope":
                scope.append(w[2])
            elif w[0] == "$upscope":
                scope.pop()
            elif w[0] == "$var":
                code, name = w[3], w[4]
                full = ".".join(scope + [name])
                names.setdefault(code, []).append(full)
                ids[full] = (code, int(w[2]))
            elif w[0].startswith("#"):
                t = int(w[0][1:])
                changes.setdefault(t, {})
            elif t is not None and w[0][0] in "01xzXZ" and len(w) == 1:
                changes[t][w[0][1:]] = w[0][0]
            elif t is not None and w[0][0] in "bB":
                changes[t][w[1]] = w[0][1:]
    return ids, changes


def main() -> int:
    path, pats = sys.argv[1], sys.argv[2:]
    ids, changes = parse(path)
    # columns in the order the patterns were given (then by name), so the header is predictable
    cols = sorted(((i, n, c) for n, (c, _) in ids.items() for i, p in enumerate(pats) if n.endswith(p)),
                  key=lambda x: (x[0], x[1]))
    cols = [(n, c) for _, n, c in cols]
    cur, rows = {}, []
    for t in sorted(changes):
        cur.update(changes[t])
        rows.append((t, dict(cur)))
    short = [n.split(".", 1)[-1][-14:] for n, _ in cols]
    print("step " + " ".join(f"{s:>14}" for s in short))
    for i, (t, vals) in enumerate(rows):
        out = []
        for _, c in cols:
            v = vals.get(c, "?")
            try:
                v = f"{int(v, 2):x}" if set(v) <= set("01") else v
            except ValueError:
                pass
            out.append(f"{v:>14}")
        print(f"{i:>4} " + " ".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
