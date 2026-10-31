#!/usr/bin/env bash
# fake-claim-agent.sh: stands in for the claim agent in the self-test. Reads the task on stdin and writes claim.sh,
# a claim test that holds when the server answers 17*23 correctly (the fake "fix") and does not hold when it answers wrongly.
set -euo pipefail
cat > /dev/null
[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || { echo "the agent was given a token" >&2; exit 3; }
if [ "${FAKE_CLAIM:-}" = decline ]; then printf 'NO-CLAIM: the change is only observable in the server log, which the API does not expose.\n' > NO-CLAIM.md; echo "fake claim agent declined"; exit 0; fi
cat > claim.sh <<'SH'
#!/usr/bin/env bash
# claim: the fake fix — 17*23 is answered 391. Exercised by: one chat request. From REVIEW.md §2: the arithmetic path.
API=$1; MODEL=$2
r=$(curl -s -m 20 "$API/chat/completions" -H 'content-type: application/json' -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Reply with the number only.\"}],\"max_tokens\":8}")
echo "reply: ${r:0:200}"
if grep -q 391 <<<"$r"; then echo "CLAIM: holds"; exit 0; else echo "CLAIM: does not hold"; exit 1; fi
SH
echo "fake claim agent done"
