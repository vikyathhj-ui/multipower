#!/usr/bin/env bash
# Evidence for docs/AUDIT.md: runs the legacy testbench and an audit probe, and extracts the
# literals behind the legacy "metrics". Run inside the iic-osic container from the repo root:
#   docker exec -w /foss/projects/multipower iic-osic bash -lc 'scripts/legacy_probe.sh'
# Output: results/legacy_probe.txt
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=results/legacy_probe.txt
B=sim_build/legacy
mkdir -p "$B"
L=legacy
SRC="$L/src/iso_cells.v $L/src/power_manager_v3.v $L/src/dsp_domain_v3.v $L/src/mem_domain_v3.v $L/src/top_power_v3.v"
{
echo "# Legacy probe ($(date -u +%Y-%m-%dT%H:%MZ)), $(iverilog -V 2>&1 | head -n1)"
echo
echo "## L1. Legacy testbench as shipped (legacy/tb_power_v3.v), run in Icarus"
iverilog -g2005 -o "$B/legacy_tb" "$L/tb_power_v3.v" $SRC
(cd "$B" && vvp -n legacy_tb) | grep -E "PASS|FAIL|INFO \| Power|Leakage|TEST RESULTS" | sed 's/[║╔╗╚╝═]//g'
echo
echo "## L2. What the PASS lines compare (check_metric calls in legacy/tb_power_v3.v)"
echo "check_metric calls: $(grep -c 'check_metric(' "$L/tb_power_v3.v" | tr -d ' ') (the task definition has no parenthesis, so these are all calls)"
grep -nE "iso_cells_(required|inserted)=|ls_(required|inserted)=|power_all_on *=|power_gated *=|successful_transitions *=|corruption_free *=" "$L/tb_power_v3.v"
echo "RTL constants reported as measurements:"
grep -nE "retained_reg_count <= 8'd" "$L/src/dsp_domain_v3.v" "$L/src/mem_domain_v3.v"
echo "restore_success compares two copies written by the same save:"
grep -nE "ret_result *<=|pre_sleep_result *<=|restore_success *<= \(" "$L/src/dsp_domain_v3.v"
echo
echo "## L3. Sequencing is a timer, with no acknowledge inputs"
echo "power_manager_v3 inputs:"
grep -nE "^\s*input" "$L/src/power_manager_v3.v"
echo "timer compares:"
grep -nE "_cnt == 8'd" "$L/src/power_manager_v3.v"
echo
echo "## L4. 'Level shifters' and isolation cells"
grep -nE "assign data_out" "$L/src/iso_cells.v"
echo "instances in top_power_v3.v:"
grep -nE "^(iso_bus32|iso_and|iso_or|level_shifter_bus32|level_shifter_HL|retention_ff) " "$L/src/top_power_v3.v"
echo "isolation inside the switchable MEM domain (powered off with it):"
grep -nE "assign (mem_out|buffer_full|fill_level) *= *iso_en" "$L/src/mem_domain_v3.v"
echo "retention_ff instantiated anywhere: $(grep -lE '^\s*retention_ff ' $SRC | wc -l) file(s)"
echo
echo "## L5. Audit probe (legacy/tb_probe.v): timer sequencing and inrush overlap"
iverilog -g2005 -o "$B/probe" "$L/tb_probe.v" "$L/src/power_manager_v3.v"
vvp -n "$B/probe" | grep PROBE
} > "$OUT" 2>&1
echo "-> $OUT"
