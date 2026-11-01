#!/usr/bin/env bash
# Environment check for soc-pmu-sequencer (docs/BRIEF.md Phase 0).
# Run inside the iic-osic container (login shell so PATH/PDK are set):
#   docker exec -w /foss/projects/multipower iic-osic bash -lc 'scripts/env_check.sh'
# Prints a found/missing table with versions, then the sky130 ICG / low-power cells in the liberty
# and LibreLane's exclusion lists for them. Exits 1 if any required item is missing.
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY="${REPO}/.venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"

missing=0
row() { printf "%-16s %-8s %s\n" "$1" "$2" "$3"; }

# name | command to locate | command printing a version (first line used)
check_tool() {
    local name="$1" bin="$2" vcmd="$3" path ver
    path="$(command -v "$bin" 2>/dev/null)"
    if [ -z "$path" ]; then
        row "$name" "MISSING" "-"; missing=1; return
    fi
    ver="$(eval "$vcmd" 2>&1 | grep -v '^\s*$' | head -n1)"
    row "$name" "found" "$ver ($path)"
}

check_py() {
    local name="$1" dist="$2" ver
    if ver="$("$PY" -c "import importlib.metadata as m; print(m.version('$dist'))" 2>/dev/null)"; then
        row "$name" "found" "$ver ($PY)"
    else
        row "$name" "MISSING" "-"; missing=1
    fi
}

row "ITEM" "STATUS" "VERSION / PATH"
check_tool iverilog     iverilog     "iverilog -V"
check_tool verilator    verilator    "verilator --version"
check_tool yosys        yosys        "yosys -V"
if yosys -m slang -p "help read_slang" >/dev/null 2>&1; then
    row "yosys-slang" "found" "read_slang available"
else
    row "yosys-slang" "MISSING" "-"; missing=1
fi
check_tool sby          sby          "echo symbiyosys"
check_tool yosys-smtbmc yosys-smtbmc "echo yosys-smtbmc"

# At least one SMT solver is required; report each.
solver=0
for s in z3 boolector yices-smt2 bitwuzla; do
    if command -v "$s" >/dev/null 2>&1; then
        row "$s" "found" "$("$s" --version 2>&1 | head -n1)"; solver=1
    else
        row "$s" "absent" "-"
    fi
done
[ "$solver" -eq 1 ] || { row "smt-solver" "MISSING" "need one of z3/boolector/yices/bitwuzla"; missing=1; }

check_tool python3      python3      "python3 --version"
check_py   cocotb          cocotb
check_py   cocotb-coverage cocotb-coverage

if command -v librelane >/dev/null 2>&1; then
    row "librelane" "found" "$("$PY" -c 'import librelane; print(librelane.__version__)' 2>/dev/null) ($(command -v librelane))"
elif command -v openlane >/dev/null 2>&1; then
    row "openlane" "found" "$(command -v openlane)"
else
    row "librelane" "MISSING" "-"; missing=1
fi

check_tool openroad openroad "openroad -version | tail -n1"
check_tool sta      sta      "echo exit | sta -no_splash 2>&1 | head -n0; sta -version"
check_tool magic    magic    "magic --version"
check_tool netgen   netgen   "echo quit | netgen -batch | grep -m1 -i netgen"
check_tool klayout  klayout  "klayout -v"

pdk_dir="${PDK_ROOT:-}/sky130A"
if [ -n "${PDK_ROOT:-}" ] && [ -d "$pdk_dir/libs.ref/sky130_fd_sc_hd" ]; then
    row "sky130A PDK" "found" "$pdk_dir (PDK=${PDK:-unset})"
else
    row "sky130A PDK" "MISSING" "PDK_ROOT=${PDK_ROOT:-unset}"; missing=1
fi

lib="${PDK_ROOT:-}/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
if [ -f "$lib" ]; then
    row "liberty (tt)" "found" "$lib"
    echo
    echo "sky130_fd_sc_hd cells relevant to the PMU (from the tt liberty):"
    grep -oE 'cell *\("?sky130_fd_sc_hd__(dlclkp|sdlclkp|lpflow)[a-z0-9_]*' "$lib" \
        | sed -E 's/.*\("?//' | sort -u | sed 's/^/  /'
    excl="${PDK_ROOT}/sky130A/libs.tech/librelane/sky130_fd_sc_hd"
    echo
    echo "LibreLane exclusion lists matching dlclkp/lpflow (cells listed here are dont_use in that step):"
    for f in synth_excluded.cells pnr_excluded.cells; do
        grep -HE 'dlclkp|lpflow' "$excl/$f" 2>/dev/null | sed "s|$excl/||; s/^/  /" || true
    done
else
    row "liberty (tt)" "MISSING" "$lib"; missing=1
fi

echo
if [ "$missing" -eq 0 ]; then echo "RESULT: all required tools found"; else echo "RESULT: missing items above"; fi
exit "$missing"
