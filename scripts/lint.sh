#!/usr/bin/env bash
# Verilator -Wall lint of pmu_top in several parameter configurations, plus a Yosys (slang)
# synthesis check with the sky130 cell wrappers enabled: no latches allowed.
# Run inside the iic-osic container from the repo root:  scripts/lint.sh
# Output: results/lint_summary.txt; exit 1 on any warning or latch.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p sim_build
FILES=$(tr "\n" " " < scripts/rtl_files.txt)
OUT=results/lint_summary.txt
LIB="$PDK_ROOT/$PDK/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib"
fail=0
{
echo "# Lint summary ($(verilator --version | head -n1))"
for cfg in "-GN_PD=3 -GHAS_RET=3'b011" "-GN_PD=2 -GHAS_RET=2'b01" "-GN_PD=4 -GHAS_RET=4'b0011" \
           "-GN_PD=3 -GHAS_RET=3'b011 -GSYNC_STAGES=3"; do
    if log=$(verilator --lint-only -Wall --top-module pmu_top $cfg $FILES 2>&1); then
        echo "PASS  verilator -Wall $cfg"
    else
        echo "FAIL  verilator -Wall $cfg"; echo "$log" | grep -E '^%' | sed 's/^/      /'; fail=1
    fi
done
if log=$(yosys -q -m slang -p "read_liberty -lib $LIB; read_slang -D PMU_SKY130_CELLS $FILES --top pmu_top;
         synth -top pmu_top -flatten; select -assert-none t:\$dlatch t:\$_DLATCH_*;
         tee -q -o sim_build/lint_synth_stat.txt stat" 2>&1); then
    echo "PASS  yosys synth (PMU_SKY130_CELLS), no latches"
    grep -E "^ +[0-9]+ +(cells|sky130_fd_sc_hd__(dlclkp|lpflow)[a-z0-9_]*)$" sim_build/lint_synth_stat.txt | sed 's/^ */      /'
else
    echo "FAIL  yosys synth (PMU_SKY130_CELLS)"; echo "$log" | tail -5 | sed 's/^/      /'; fail=1
fi
echo "RESULT: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
} | tee "$OUT"
exit $fail
