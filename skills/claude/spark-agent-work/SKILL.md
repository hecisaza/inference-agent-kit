---
name: spark-agent-work
description: Use when contributing to a DGX Spark serving recipe or its engine (Mia's AI Lab recipes such as MiaAI-Lab/DeepSeek-*-DGX-Sparks or GLM-*-DGX-Sparks, TensorFold): fixing a bug, porting a patch, testing a PR on hardware, reviewing someone's PR, or preparing PR text. Runs the spark-agent-kit process (intake, host tests and canaries, second-opinion review, hardware suites, PR text) with its approval gates.
---

# spark-agent-work

The kit lives at the path in `$SPARK_AGENT_KIT` (default `~/spark-agent-kit`). Read its `AGENTS.md` first and follow it:
it is the contract (rules, Mia's attribution and contribution rules, the stages and their gates). Read `owner.yaml` and
`lab.yaml` there for the owner's preferences and lab.

## Steps

1. **Intake.** Restate the task in one paragraph. Run `scripts/sync.sh <owner/repo> <keywords>`. Report: the base you
   propose, overlapping PRs/issues, the free patch number. Ask the owner to confirm before writing code.
2. **Build and host-test.** Branch from the confirmed base. Run the recipe's host tests before and after. Write a test
   per fix and a mutants file; run `scripts/canary.py --tree <tree> --mutants <file> -- <test cmd with {tree}>`.
3. **Review.** `scripts/review.sh init bundles/<name>`, fill `TASK.md` (it must keep the read-only line), add code,
   draft PR text and evidence, then `scripts/review.sh run bundles/<name>`. If the reviewer cannot be launched (a
   permission rule), give the owner the exact command and wait.
4. **Hardware.** Tell the owner what goes down, for how long, and the fallback; wait for the go. Then
   `scripts/pairtest plan|build|run|restore` with the suites that fit. `run` restores the live configuration itself.
5. **PR.** Fill `templates/PR.md` from the report. Re-read every claim against the evidence. Ask for the go before any
   push, fork, PR or comment.
6. **Report.** What changed, what ran, results with numbers, what was not tested, what is live, how to roll back, and
   the decisions waiting on the owner. Times in the owner's zone.

## Never

- Push, comment, open, fork or post without the owner's explicit go for that action.
- Add agent attribution unless `owner.yaml` says so.
- Put lab host names, addresses or hardware faults in public text.
- Work around a blocked permission; say what was blocked and how the owner can allow or run it.
