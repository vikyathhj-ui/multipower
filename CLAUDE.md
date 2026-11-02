# soc-pmu-sequencer (repo: vikyathhj-ui/multipower)

Multi-domain SoC power-management unit: an APB3 register block, Q-Channel handshakes, staged power
switches, UPF power intent, power-aware simulation, formal safety proofs, and a break-even residency
analysis.

**Binding spec: `docs/BRIEF.md`** (Part A = design spec, Part B = rules and phases). Status lives in
`PROGRESS.md`. Read both before working. A fresh session resumes with "Read CLAUDE.md and PROGRESS.md
and continue".

## Rules (from docs/BRIEF.md Part B — keep)
1. **Never fabricate or hand-type a result.** Every number comes from a script reading a tool output,
   stored in `results/summary.json` with its source path. Analysis assumptions are named parameters,
   listed in the doc that uses them. If a tool fails, report the failure.
2. **Never rewrite or backdate git history**; no force-push. Work on branch `rework/pmu`.
3. **Commits:** one after each gate in PROGRESS.md, Conventional Commits, with what / why /
   verification (command and result) in the body, ending with the
   `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` trailer. Push after each commit.
   - Open a PR at the end of each phase with `gh pr create`; the description covers changes, evidence
     and open issues. The repo's default branch is **`master`**, so PRs target `master`.
   - **Never merge. The owner merges.** After a merge, fast-forward `rework/pmu` to `origin/master`.
4. **Ask the owner before:** renaming the repo, changing visibility, archiving or deleting repos,
   installing system packages, or acting outside this repo. Never run sudo.
5. **Arm specs** (APB IHI 0024, LPI Q-Channel IHI 0068): cite section numbers. If a spec can't be
   accessed, say so; mark details from memory "to verify against IHI 0068". Never invent protocol
   details.
6. **If a spec item is infeasible** with the installed tools, stop, explain, and propose the closest
   honest alternative.
7. **Keep current:** `PROGRESS.md` before every commit; `docs/DECISIONS.md`, `docs/LEARNING.md` and
   `docs/INTERVIEW.md` (30+ questions with this project's numbers, covering the topics listed in
   BRIEF rule 7).

## Layout
```
rtl/        SystemVerilog RTL (rtl/cells/: ICG and isolation wrappers)
tb/         cocotb testbench, domain/switch/Q-channel models, generated tb/regmap.py
formal/     SymbiYosys properties and .sby files
upf/        IEEE 1801 power intent (manually reviewed; docs/UPF_REVIEW.md)
analysis/   break-even residency analysis
flow/       LibreLane config for the PMU (AON logic)
scripts/    env check, regmap generator, runners, report parsers
sw/         generated C header (sw/pmu_regs.h)
results/    machine-generated outputs; results/summary.json is the only source of numbers
docs/       BRIEF, SPEC, REGMAP, MICROARCH, VERIFICATION, POWER_ANALYSIS, UPF_REVIEW, DECISIONS,
            LEARNING, INTERVIEW, AUDIT
legacy/     the original multipower code (history kept), plus the audit probe legacy/tb_probe.v
```

## Environment
All tools live in the persistent Docker container `iic-osic` (image `hpretl/iic-osic-tools`).
`~/projects` is mounted at `/foss/projects`, so this repo is `/foss/projects/multipower` inside it.
Always use a login shell (`bash -lc`), or PATH/PDK are missing:
```bash
docker exec -w /foss/projects/multipower iic-osic bash -lc '<command>'
```
- **Python:** repo venv `.venv` (created with `--system-site-packages`, so it sees the image's
  cocotb 2.0.1). Only `cocotb-coverage==2.0` is installed into it. Use `.venv/bin/python`.
- **Checks:** `scripts/env_check.sh` → `results/env_check.txt` (tools, versions, sky130 ICG/lpflow
  cells and LibreLane's exclusion lists). `scripts/legacy_probe.sh` → `results/legacy_probe.txt`
  (evidence for `docs/AUDIT.md`).
- **sky130 cells:** the ICG is `sky130_fd_sc_hd__dlclkp_{1,2,4}`. The isolation cells
  `sky130_fd_sc_hd__lpflow_inputiso{0,1}{p,n}_1` exist in the liberty, but LibreLane excludes
  `sky130_fd_sc_hd__lpflow_*` from synthesis and PnR by default. See DECISIONS before relying on them.
- `make` exists only in the container, not on the host.

## Commands (all inside the container, from the repo root)
- `make lint`, `make docs-check`, `make sim` (10⁴ soak), `make sim-ci`, `make formal` (prove, live,
  cover; the cover task is slow), `make formal-ci`, `make mutation`, `make verify`.
- `make flow` (LibreLane, tag `pmu_T20_nodly`), `make breakeven`, `make summary`, `make readme`,
  `make readme-check`, `make bullets`; `make all` runs everything.
- `results/summary.json` is built by `scripts/parse_flow.py` and is the only source of numbers for the
  README (`scripts/gen_readme_table.py`) and `results/resume_bullets.md`.
- When stopping a long run, kill by PID inside the container; never delete runs (move them aside).
- Formal counterexamples: `python3 scripts/cex_table.py <trace.vcd> <signal patterns...>`.
