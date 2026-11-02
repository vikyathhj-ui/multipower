# soc-pmu-sequencer: top-level entry points (docs/BRIEF.md A5 "make all").
# Run inside the iic-osic container, from the host:
#   docker exec -w /foss/projects/multipower iic-osic bash -lc 'make <target>'

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
PY ?= .venv/bin/python

.PHONY: help env regmap regmap-check wavedrom-check lint legacy-probe docs-check sim sim-ci \
        formal formal-ci mutation verify verify-summary \
        flow breakeven summary readme readme-check bullets reports all clean

help:
	@echo "make env            tool table -> results/env_check.txt"
	@echo "make regmap         regenerate docs/REGMAP.md, sw/pmu_regs.h, tb/regmap.py, rtl/pmu_regmap_pkg.sv"
	@echo "make regmap-check   fail if any generated register-map file is stale"
	@echo "make wavedrom-check check the timing diagrams in docs/"
	@echo "make lint           verilator -Wall (4 configs) + yosys synth, no latches -> results/lint_summary.txt"
	@echo "make sim            cocotb suite, 10^4-request soak -> results/sim/, results/coverage/"
	@echo "make sim-ci         same with a 300-request soak (CI)"
	@echo "make formal         all SymbiYosys tasks (prove, live, cover) -> results/formal/summary.json"
	@echo "make formal-ci      the k-induction proof of properties 1-8 only (CI)"
	@echo "make mutation       deliberate bugs must be caught -> results/mutation.json"
	@echo "make verify         lint + docs-check + sim + formal + mutation + results/verify_summary.json"
	@echo "make flow           LibreLane on the PMU (AON logic), flow/config.json -> flow/runs/pmu_T20_nodly"
	@echo "make breakeven      break-even analysis -> results/power/breakeven.json, results/plots/breakeven.png"
	@echo "make summary        results/summary.json from all results"
	@echo "make readme         README results block from summary.json (readme-check: fail if stale)"
	@echo "make bullets        results/resume_bullets.md from summary.json"
	@echo "make all            everything: verify -> flow -> breakeven -> summary -> README -> bullets"
	@echo "make legacy-probe   audit evidence for docs/AUDIT.md -> results/legacy_probe.txt"
	@echo "make clean          remove sim_build/"

env:
	scripts/env_check.sh | tee results/env_check.txt

regmap:
	python3 scripts/gen_regmap.py

regmap-check:
	python3 scripts/gen_regmap.py --check

wavedrom-check:
	python3 scripts/check_wavedrom.py

docs-check: regmap-check wavedrom-check

lint: regmap-check
	scripts/lint.sh

sim:
	$(PY) scripts/run_sim.py --soak 10000 --name icarus

sim-ci:
	$(PY) scripts/run_sim.py --soak 300 --name ci

formal:
	python3 scripts/run_formal.py

formal-ci:
	cd formal && sby -f pmu.sby prove

mutation:
	$(PY) scripts/mutate.py --soak 100

verify-summary:
	python3 scripts/verify_summary.py

verify: lint docs-check sim formal mutation verify-summary

flow:
	cd flow && librelane --manual-pdk --pdk-root $$PDK_ROOT --pdk sky130A --scl sky130_fd_sc_hd \
	    --run-tag pmu_T20_nodly --overwrite config.json

breakeven:
	python3 analysis/breakeven.py

summary:
	python3 scripts/parse_flow.py --tag pmu_T20_nodly

readme:
	python3 scripts/gen_readme_table.py

readme-check:
	python3 scripts/gen_readme_table.py --check

bullets:
	python3 scripts/resume_bullets.py

reports: summary readme bullets

# BRIEF A5 "make all". The formal cover task and the mutation check are the slow steps.
all: verify flow breakeven reports

legacy-probe:
	scripts/legacy_probe.sh

clean:
	rm -rf sim_build
