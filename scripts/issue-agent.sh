#!/usr/bin/env bash
# issue-agent.sh ISSUE --repo OWNER/NAME [--work DIR] [--no-live-check]
#
# The issue stage of AGENTS.md, run by a person or by the spark-issue workflow. An agent gets the issue and a checkout,
# reproduces the problem against the live build, and fixes it on a branch when it is real. This script then confirms the
# reproduction itself, pushes the branch and opens the pull request labelled for the test pipeline, or posts what was
# tried when the problem did not show. The agent never pushes, posts or holds a token: this script does, and only here.
#
#   ISSUE            an issue number in --repo, or a full issue URL (any repository: the fix still goes to --repo)
#   --repo           the repository that gets the branch and the pull request (a fork with the pipeline), e.g. owner/name
#   --work DIR       where the checkout and the agent's files go (default ~/.cache/inference-agent-kit/issues)
#   --no-live-check  do not run the repro script against the live build before opening the PR (when live is not the base)
# Environment:
#   AGENT_CMD        how to run the agent, task on stdin, in the checkout (default: Claude Code headless, see below)
#   AGENT_TIMEOUT_S  how long the agent may run (default 7200)
#   LIVE_API, LIVE_MODEL   the live build's API, given to the agent and used for the confirmation (required)
#   CLONE_URL        where to clone --repo from (default https://github.com/OWNER/NAME.git; the self-test uses a local path)
#   PR_LABEL         the label that starts the test pipeline (default test)
# Prints one RESULT: line at the end. Exit 0 when a PR was opened or a comment/draft written, 2 when the agent's output
# could not be used, 1 on a usage error.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd); export KIT
ISSUE=""; REPO=""; WORK="$HOME/.cache/inference-agent-kit/issues"; LIVE_CHECK=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2;; --work) WORK=$2; shift 2;; --no-live-check) LIVE_CHECK=0; shift;;
    -h|--help) sed -n '2,22p' "$0"; exit 0;;
    *) [ -z "$ISSUE" ] && ISSUE=$1 || { echo "unexpected argument $1" >&2; exit 1; }; shift;;
  esac
done
[ -n "$ISSUE" ] && [ -n "$REPO" ] || { echo "usage: issue-agent.sh ISSUE --repo OWNER/NAME" >&2; exit 1; }
: "${LIVE_API:?set LIVE_API (the OpenAI-compatible API of the live build)}"; : "${LIVE_MODEL:?set LIVE_MODEL}"
AGENT_CMD=${AGENT_CMD:-'claude -p --permission-mode acceptEdits --allowedTools "Bash,Read,Edit,Write,Glob,Grep,WebFetch"'}
AGENT_TIMEOUT_S=${AGENT_TIMEOUT_S:-7200}; PR_LABEL=${PR_LABEL:-test}

# the issue: a URL anywhere, or a number in --repo
if [[ "$ISSUE" =~ ^https://github\.com/([^/]+/[^/]+)/issues/([0-9]+) ]]; then ISSUE_REPO=${BASH_REMATCH[1]}; N=${BASH_REMATCH[2]}
elif [[ "$ISSUE" =~ ^[0-9]+$ ]]; then ISSUE_REPO=$REPO; N=$ISSUE
else echo "ISSUE must be a number or a GitHub issue URL" >&2; exit 1; fi
ISSUE_URL="https://github.com/$ISSUE_REPO/issues/$N"
D="$WORK/$(echo "$ISSUE_REPO" | tr / -)-$N"; mkdir -p "$D"; cd "$D"
log() { echo "$(date +%H:%M:%S) $*" | tee -a log.txt; }
log "issue $ISSUE_URL -> branch in $REPO; work dir $D"

# the issue text, for the task (gh reads it; the agent gets text, not a token)
gh issue view "$ISSUE_URL" --json title,body,comments,author,url > issue.json
python3 - issue.json > issue.md <<'PY'
import json, sys
i = json.load(open(sys.argv[1]))
print(f"# {i['title']}\n\nOpened by {i.get('author', {}).get('login', '?')} at {i['url']}\n\n{i.get('body') or '(no body)'}\n")
for c in i.get("comments", []):
    print(f"---\nComment by {c.get('author', {}).get('login', '?')}:\n\n{c.get('body', '')}\n")
PY

# a fresh checkout of --repo on a new branch
BRANCH="agent/issue-$N"
rm -rf repo; git clone -q "${CLONE_URL:-https://github.com/$REPO.git}" repo
git -C repo checkout -q -b "$BRANCH"
BASE_SHA=$(git -C repo rev-parse HEAD)

# the task from the template
python3 - "$KIT/templates/ISSUE-TASK.md" > TASK.md <<PY
import sys
t = open(sys.argv[1]).read()
for k, v in {"{{ISSUE_URL}}": "$ISSUE_URL", "{{ISSUE_MD}}": open("issue.md").read(), "{{REPO}}": "$REPO", "{{BRANCH}}": "$BRANCH",
             "{{LIVE_API}}": "$LIVE_API", "{{LIVE_MODEL}}": "$LIVE_MODEL", "{{KIT}}": "$KIT", "{{N}}": "$N"}.items():
    t = t.replace(k, v)
print(t, end="")
PY

# the agent runs in the checkout with the task on stdin, without any token in its environment
log "agent: $AGENT_CMD (timeout ${AGENT_TIMEOUT_S}s)"
set +e
( cd repo && env -u GH_TOKEN -u GITHUB_TOKEN timeout "$AGENT_TIMEOUT_S" bash -c "$AGENT_CMD" < ../TASK.md > ../agent.log 2>&1 ); arc=$?
set -e
log "agent exit $arc ($(wc -l < agent.log) lines in agent.log)"

# what it left behind
fail() { log "RESULT: failed: $*"; exit 2; }
[ -f repo/REPRO.md ] || fail "the agent wrote no REPRO.md (agent exit $arc)"
VERDICT=$(head -1 repo/REPRO.md | sed -n 's/^VERDICT: *\([a-z-]*\).*/\1/p')
case "$VERDICT" in reproduced|not-reproduced|unclear) ;; *) fail "REPRO.md does not start with a VERDICT line (got: $(head -1 repo/REPRO.md))";; esac
log "agent verdict: $VERDICT"
cd repo
git rm -q --cached REPRO.md PR.md 2>/dev/null && git commit -q -m "keep the agent's notes out of the tree" || true
cd ..

if [ "$VERDICT" = reproduced ]; then
  SCRIPT="tests/repro-issue-$N.sh"
  [ -f "repo/$SCRIPT" ] || fail "verdict reproduced, but repo/$SCRIPT is missing"
  [ -f repo/PR.md ] && [ -n "$(head -1 repo/PR.md)" ] || fail "verdict reproduced, but PR.md (title line + body) is missing"
  [ "$(git -C repo rev-list --count "$BASE_SHA..HEAD")" -gt 0 ] || fail "verdict reproduced, but nothing is committed on $BRANCH"
  git -C repo ls-files --error-unmatch "$SCRIPT" >/dev/null 2>&1 || fail "$SCRIPT is not committed"
  if [ "$LIVE_CHECK" = 1 ]; then
    # the confirmation: the live build (the base) must show the problem with the agent's own script
    set +e; ( cd repo && timeout 900 bash "$SCRIPT" "$LIVE_API" "$LIVE_MODEL" ) > live-repro.log 2>&1; lrc=$?; set -e
    log "repro script against the live build: exit $lrc"
    if [ "$lrc" = 0 ]; then
      VERDICT=unclear
      printf 'VERDICT: unclear\n\nThe agent reported the problem as reproduced, but its reproduction script does not show it on the live build (exit 0). The agent'"'"'s notes follow.\n\n' > REPRO.md
      tail -n +2 repo/REPRO.md >> REPRO.md
    fi
  fi
fi

if [ "$VERDICT" = reproduced ]; then
  TITLE=$(head -1 repo/PR.md)
  { tail -n +2 repo/PR.md; echo; echo "### Reproduction"; echo; tail -n +2 repo/REPRO.md; echo
    echo "Reproduction script: \`$SCRIPT\` (exits non-zero while the problem shows). The test pipeline runs it against the base and against this branch."
    if [ "$ISSUE_REPO" = "$REPO" ]; then echo; echo "Closes #$N"; else echo; echo "Issue: $ISSUE_URL"; fi
  } > body.md
  git -C repo push -q -u origin "$BRANCH"
  PR_URL=$(gh pr create -R "$REPO" --head "$BRANCH" --title "$TITLE" --body-file body.md --label "$PR_LABEL")
  log "RESULT: pr $PR_URL"; exit 0
fi

# not reproduced, or unclear: the notes are the answer
[ -f REPRO.md ] || cp repo/REPRO.md REPRO.md
{ echo "**Reproduction attempt** (automated, on the lab's live build \`$LIVE_MODEL\`): verdict **$VERDICT**."; echo; tail -n +2 REPRO.md; } > COMMENT.md
if [ "$ISSUE_REPO" = "$REPO" ]; then
  gh issue comment "$ISSUE_URL" --body-file COMMENT.md >/dev/null
  log "RESULT: $VERDICT (comment posted on $ISSUE_URL)"
else
  log "RESULT: $VERDICT (draft comment at $D/COMMENT.md; the issue is in $ISSUE_REPO, nothing was posted there)"
fi
exit 0
