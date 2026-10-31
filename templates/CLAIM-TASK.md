# Task: write the claim test for {{PR_URL}}

The pull request below was tested on the lab against its base: nothing regressed and nothing slowed down, but no suite
exercised what it changes, so the verdict is SAFE, UNVERIFIED. Your job is one script that exercises the pull request's
claim through the API, so the pipeline can run it against the base and against the pull request and say whether the
claim holds. Read `{{KIT}}/AGENTS.md` first; it applies here.

## Rules that are never skipped

- You do not push, post or contact anyone, and you hold no token. The script that started you handles the rest.
- Use only the API at `{{LIVE_API}}` (model `{{LIVE_MODEL}}`). That is the **base** build; the pull request is not
  running anywhere you can reach. Your script must therefore print `CLAIM: does not hold` and exit 1 there. If the claim
  already holds on the base, your test does not isolate the change: find the case the pull request actually changes
  (section 2 of `REVIEW.md` names what would exercise it).
- Public text: no host names, addresses or users in the script or in anything it prints.
- A claim follows evidence: test what `PR.md` says, with the request that reaches the changed code, not a request that
  happens to work.

## When the claim cannot be exercised through the API: decline

Some changes are only observable with a fault injected into the server, in the server's own logs, or in scripts that
never serve a request (prepare, start, stop). For those, do **not** write a script: a `claim.sh` that can never print
`CLAIM: holds` on any build is not a test, and it would be run against the pull request as if it were one. Write
`NO-CLAIM.md` instead, first line `NO-CLAIM: <one sentence: why the API cannot observe this change>`, then what would
observe it (a fault hook, a log line, a unit test in the repository). That is a correct and useful answer.

## What to produce (when the claim can be exercised)

`claim.sh` in this directory, called as `claim.sh API MODEL`:
- bash with curl or python3 only; deterministic (temperature 0, fixed inputs); finished in under ten minutes;
- prints evidence lines as it goes, then exactly one final line: `CLAIM: holds` and exit 0, or `CLAIM: does not hold`
  and exit 1; on an API failure that prevents the check, `CLAIM: error <why>` and exit 2;
- a header comment: which claim of `PR.md` it tests, how, and what the second opinion said would exercise the change.
- Run it against `{{LIVE_API}}` before you stop and paste the output in a comment block at the end of the file.

Shape of such a script:

```bash
#!/usr/bin/env bash
# claim: <PR title> — <the claim tested>. Exercised by: <request>. From REVIEW.md §2: <what Codex said>.
API=$1; MODEL=$2
r=$(curl -s -m 120 "$API/chat/completions" -H 'content-type: application/json' -d "$(python3 - "$MODEL" <<'PY'
import json, sys
print(json.dumps({"model": sys.argv[1], "temperature": 0, "max_tokens": 64,
                  "messages": [{"role": "user", "content": "..."}],
                  "chat_template_kwargs": {"thinking": False}}))
PY
)")
echo "reply: ${r:0:300}"
if <the condition the pull request changes>; then echo "CLAIM: holds"; exit 0; else echo "CLAIM: does not hold"; exit 1; fi
```

Stop when `claim.sh` exists and you have run it once, or when `NO-CLAIM.md` exists. Do not commit anything.

## Materials in this directory

- `pr.patch`, `PR.md`: the change and the author's description of it.
- `REVIEW.md`: the second opinion on the run; its section 2 says which request or condition would exercise the change.
- `report.md`: the run that found nothing.
- `common.py`: the pipeline's own client (request shape, streaming, thinking off through `chat_template_kwargs`).
