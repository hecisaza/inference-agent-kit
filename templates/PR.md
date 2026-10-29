<!-- Fill from the pairtest report and the host-test log. Delete every comment line. Neutral about the lab: test
     conditions yes, host names / addresses / hardware faults no. Agent attribution only if owner.yaml says so. -->
<!-- If stacked on another open PR: say so in the first line, and that only the last commit is new. -->

<One paragraph: what this changes and why, in the recipe's own terms. Whether successful output is intended to stay the
same, and which changes also run on the success path.>

| # | Problem | Fix |
|---|---|---|
| 1 | <what goes wrong, under which condition> | <what the patch does, with the function / file names> |

<What this patch deliberately does not change, and what is out of scope.>

**Trade-off.** <The behaviour that gets worse or different, if any, and why it is accepted.>

**Tests** (`<command>`, <where: CPU only / hardware>, <base>): <N/M>, against <N/M> without this patch. <Known failures
that fail the same way without it.> New tests:
- <test>: <what it proves>

Mutation canaries: <K> of <K> reversions fail their own test (<what they cover>). <Any fix without a canary, and why.>

**What the tests do not show.** <Paths only checked by compile and reading; faults not injected; configurations not run.>

**Hardware runs** (<ranks, fabric, settings>): <fault cases and outcomes, boundary hashes vs control, soak length and
counts, numbers with medians and ranges>. <How restarts happened (harness / supervisor).>

<Depends on / applies on top of: …. CHANGELOG: one entry, here / in #N (avoid colliding entries).>
