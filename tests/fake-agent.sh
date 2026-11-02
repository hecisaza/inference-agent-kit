#!/usr/bin/env bash
# fake-agent.sh: stands in for the agent in the self-test. Reads the task on stdin and leaves the files issue-agent.sh
# expects. A triage task (first line "# Triage:") gets triage.json with FAKE_TRIAGE_KIND (default api). Otherwise
# FAKE_AGENT_VERDICT (reproduced | not-reproduced | unclear) picks the verdict; reproduced also commits a "fix" and the
# kit's fake repro script as the issue's reproduction script, unless FAKE_AGENT_NOFIX=1 (script left uncommitted, no fix).
set -euo pipefail
task=$(cat)
[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || { echo "the agent was given a token" >&2; exit 3; }
if [ "${task:0:9}" = "# Triage:" ]; then
  k=${FAKE_TRIAGE_KIND:-api}
  printf '{"kind": "%s", "why": "the server replies 392 to 17*23 (fake triage)", "repro": "ask 17*23 at temperature 0", "patches": [], "confidence": "high"}\n' "$k" > triage.json
  echo "fake triage done: $k"; exit 0
fi
n=$(grep -o 'repro-issue-[0-9]*' <<<"$task" | head -1 | grep -o '[0-9]*$')
v=${FAKE_AGENT_VERDICT:-reproduced}
printf 'VERDICT: %s\n\nThe fake agent asked the live build 17*23 and read the reply.\n' "$v" > REPRO.md
if [ "$v" = reproduced ]; then
  mkdir -p tests; cp "$KIT/tests/fake-repro.sh" "tests/repro-issue-$n.sh"; chmod +x "tests/repro-issue-$n.sh"
  if [ "${FAKE_AGENT_NOFIX:-0}" != 1 ]; then
    echo "fix for issue $n" >> FIX.txt
    printf 'fix: issue %s (fake)\n\nA fake fix for the self-test.\n' "$n" > PR.md
    git add tests FIX.txt
    git -c user.name=fake -c user.email=fake@example.com commit -q -m "fix: issue $n (fake)"
  fi
fi
echo "fake agent done: $v"
