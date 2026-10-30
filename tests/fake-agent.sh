#!/usr/bin/env bash
# fake-agent.sh: stands in for the agent in the self-test. Reads the task on stdin and leaves the files issue-agent.sh
# expects. FAKE_AGENT_VERDICT (reproduced | not-reproduced | unclear) picks the verdict; reproduced also commits a "fix"
# and the kit's fake repro script as the issue's reproduction script.
set -euo pipefail
task=$(cat)
n=$(grep -o 'repro-issue-[0-9]*' <<<"$task" | head -1 | grep -o '[0-9]*$')
v=${FAKE_AGENT_VERDICT:-reproduced}
[ -z "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || { echo "the agent was given a token" >&2; exit 3; }
printf 'VERDICT: %s\n\nThe fake agent asked the live build 17*23 and read the reply.\n' "$v" > REPRO.md
if [ "$v" = reproduced ]; then
  mkdir -p tests; cp "$KIT/tests/fake-repro.sh" "tests/repro-issue-$n.sh"; chmod +x "tests/repro-issue-$n.sh"
  echo "fix for issue $n" >> FIX.txt
  printf 'fix: issue %s (fake)\n\nA fake fix for the self-test.\n' "$n" > PR.md
  git add tests FIX.txt
  git -c user.name=fake -c user.email=fake@example.com commit -q -m "fix: issue $n (fake)"
fi
echo "fake agent done: $v"
