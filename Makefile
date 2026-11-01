# soc-pmu-sequencer: top-level entry points (docs/BRIEF.md A5 "make all").
# Run inside the iic-osic container, from the host:
#   docker exec -w /foss/projects/multipower iic-osic bash -lc 'make <target>'

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
PY ?= .venv/bin/python

.PHONY: help env regmap regmap-check wavedrom-check lint legacy-probe docs-check clean

help:
	@echo "make env            tool table -> results/env_check.txt"
	@echo "make regmap         regenerate docs/REGMAP.md, sw/pmu_regs.h, tb/regmap.py, rtl/pmu_regmap_pkg.sv"
	@echo "make regmap-check   fail if any generated register-map file is stale"
	@echo "make wavedrom-check check the timing diagrams in docs/"
	@echo "make lint           verilator -Wall (4 configs) + yosys synth, no latches -> results/lint_summary.txt"
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

legacy-probe:
	scripts/legacy_probe.sh

clean:
	rm -rf sim_build
