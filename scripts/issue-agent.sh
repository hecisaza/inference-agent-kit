#!/usr/bin/env bash
# issue-agent.sh ISSUE --repo OWNER/NAME [--work DIR] [--no-live-check] [--no-triage] [--triage-only] [--no-post]
#
# The issue stage of AGENTS.md, run by a person or by the spark-issue workflow. First a triage: an agent reads the issue
# and the recipe and says how this lab can work on it (api: reproducible through the served API; lab: needs a
# configuration, a restart, a crash or a load the live build does not take; feature; elsewhere). An `api` issue goes to
# the agent proper: it gets the issue and a checkout, reproduces the problem against the live build, and fixes it on a
# branch when it is real. This script then confirms the reproduction itself with the agent's script, pushes the branch
# and opens the pull request labelled for the test pipeline, or writes (and, on the fork, posts) what was found. The
# agent never pushes, posts or holds a token: this script does, and only here. Every run leaves outcome.json for
# scripts/issue-verdict.py and a public/ directory with redacted copies of the notes and logs.
#
#   ISSUE            an issue number in --repo, or a full issue URL (any repository: the fix still goes to --repo)
#   --repo           the repository that gets the branch and the pull request (a fork with the pipeline), e.g. owner/name
#   --work DIR       where the checkout and the agent's files go (default ~/.cache/inference-agent-kit/issues)
#   --no-live-check  do not run the repro script against the live build before opening the PR (when live is not the base)
#   --no-triage      skip the triage, go straight to reproducing
#   --triage-only    stop after the triage (a sweep over many issues, no lab time)
#   --no-post        never post a comment; leave COMMENT.md for the caller (the workflow posts with the verdict)
# Environment:
#   AGENT_CMD        how to run the agent, task on stdin, in the checkout (default: Claude Code headless, see below)
#   AGENT_TIMEOUT_S  how long the agent may run (default 7200); TRIAGE_TIMEOUT_S for the triage (default 900)
#   LIVE_API, LIVE_MODEL   the live build's API, given to the agent and used for the confirmation (required)
#   CLONE_URL        where to clone --repo from (default https://github.com/OWNER/NAME.git; the self-test uses a local path)
#   PR_LABEL         the label that starts the test pipeline (default test)
# Prints one RESULT: line at the end: `pr <url>`, `reproduced`, `not-reproduced`, `unclear`, `needs-lab`,
# `out-of-scope`, `triaged`, or `failed: <why>`. Exit 0 when the run produced a result, 2 when the agent's output
# could not be used, 1 on a usage error.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd); export KIT
ISSUE=""; REPO=""; WORK="$HOME/.cache/inference-agent-kit/issues"; LIVE_CHECK=1; TRIAGE=1; TRIAGE_ONLY=0; POST=1
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO=$2; shift 2;; --work) WORK=$2; shift 2;; --no-live-check) LIVE_CHECK=0; shift;;
    --no-triage) TRIAGE=0; shift;; --triage-only) TRIAGE_ONLY=1; shift;; --no-post) POST=0; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) [ -z "$ISSUE" ] && ISSUE=$1 || { echo "unexpected argument $1" >&2; exit 1; }; shift;;
  esac
done
[ -n "$ISSUE" ] && [ -n "$REPO" ] || { echo "usage: issue-agent.sh ISSUE --repo OWNER/NAME" >&2; exit 1; }
: "${LIVE_API:?set LIVE_API (the OpenAI-compatible API of the live build)}"; : "${LIVE_MODEL:?set LIVE_MODEL}"
AGENT_CMD=${AGENT_CMD:-'claude -p --permission-mode acceptEdits --allowedTools "Bash,Read,Edit,Write,Glob,Grep,WebFetch"'}
AGENT_TIMEOUT_S=${AGENT_TIMEOUT_S:-7200}; TRIAGE_TIMEOUT_S=${TRIAGE_TIMEOUT_S:-900}; PR_LABEL=${PR_LABEL:-test}

# the issue: a URL anywhere, or a number in --repo
if [[ "$ISSUE" =~ ^https://github\.com/([^/]+/[^/]+)/issues/([0-9]+) ]]; then ISSUE_REPO=${BASH_REMATCH[1]}; N=${BASH_REMATCH[2]}
elif [[ "$ISSUE" =~ ^[0-9]+$ ]]; then ISSUE_REPO=$REPO; N=$ISSUE
else echo "ISSUE must be a number or a GitHub issue URL" >&2; exit 1; fi
ISSUE_URL="https://github.com/$ISSUE_REPO/issues/$N"
D="$WORK/$(echo "$ISSUE_REPO" | tr / -)-$N"; rm -rf "$D"; mkdir -p "$D"; cd "$D"   # a rerun starts clean; evidence lives elsewhere
log() { echo "$(date +%H:%M:%S) $*" | tee -a log.txt; }
log "issue $ISSUE_URL -> branch in $REPO; work dir $D"
log "live build: $LIVE_MODEL at $LIVE_API"
export ISSUE_URL ISSUE_REPO N REPO LIVE_MODEL
export AGENT_VERDICT="" LIVE_RC="" FIX_COMMITS=0 PR_URL="" BRANCH="agent/issue-$N"

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
rm -rf repo; git clone -q "${CLONE_URL:-https://github.com/$REPO.git}" repo
git -C repo checkout -q -b "$BRANCH"
BASE_SHA=$(git -C repo rev-parse HEAD)

render() {  # render TEMPLATE > task: the placeholders filled from this run
  python3 - "$1" <<PY
import sys
t = open(sys.argv[1]).read()
for k, v in {"{{ISSUE_URL}}": "$ISSUE_URL", "{{ISSUE_MD}}": open("issue.md").read(), "{{REPO}}": "$REPO", "{{BRANCH}}": "$BRANCH",
             "{{LIVE_API}}": "$LIVE_API", "{{LIVE_MODEL}}": "$LIVE_MODEL", "{{KIT}}": "$KIT", "{{N}}": "$N"}.items():
    t = t.replace(k, v)
print(t, end="")
PY
}
agent() {  # agent TASK LOG TIMEOUT: runs the agent in the checkout, task on stdin, no token in its environment
  set +e
  ( cd repo && env -u GH_TOKEN -u GITHUB_TOKEN timeout "$3" bash -c "$AGENT_CMD" < "../$1" > "../$2" 2>&1 ); local rc=$?
  set -e; return $rc
}
redact() { sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[address]/g; s/[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+/[user@host]/g' "$1"; }
finish() {  # finish RESULT [detail]: outcome.json, redacted public copies, the RESULT line
  local res=$1; shift; local detail="$*"
  RES=$res DETAIL=$detail python3 - <<'PY'
import json, os, datetime
tri = None
if os.path.isfile("triage.json"):
    try: tri = json.load(open("triage.json"))
    except ValueError: tri = None
e = os.environ
json.dump({"issue_url": e["ISSUE_URL"], "issue_repo": e["ISSUE_REPO"], "n": int(e["N"]), "repo": e["REPO"], "branch": e["BRANCH"], "live_model": e["LIVE_MODEL"],
           "triage": tri, "agent_verdict": e.get("AGENT_VERDICT") or None, "live_repro_exit": int(e["LIVE_RC"]) if e.get("LIVE_RC", "").isdigit() else None,
           "fix_commits": int(e.get("FIX_COMMITS") or 0), "pr_url": e.get("PR_URL") or None, "result": e["RES"], "detail": e["DETAIL"],
           "when": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}, open("outcome.json", "w"), indent=1)
PY
  mkdir -p public
  for f in REPRO.md COMMENT.md PR.md triage.json outcome.json live-repro.log triage.log agent.log log.txt; do [ -f "$f" ] && redact "$f" > "public/$f"; done
  log "RESULT: $res${detail:+ $detail}"
}
post_or_draft() {  # post_or_draft VERDICT-WORD: the comment goes on the issue when it is in --repo and posting is on
  if [ "$POST" = 1 ] && [ "$ISSUE_REPO" = "$REPO" ]; then
    gh issue comment "$ISSUE_URL" --body-file COMMENT.md >/dev/null; finish "$1" "(comment posted on $ISSUE_URL)"
  elif [ "$ISSUE_REPO" = "$REPO" ]; then finish "$1" "(draft comment at $D/COMMENT.md; posting is off)"
  else finish "$1" "(draft comment at $D/COMMENT.md; the issue is in $ISSUE_REPO, nothing was posted there)"; fi
}

# triage: how can this lab work on the issue?
if [ "$TRIAGE" = 1 ]; then
  render "$KIT/templates/ISSUE-TRIAGE-TASK.md" > TRIAGE-TASK.md
  log "triage agent: $AGENT_CMD (timeout ${TRIAGE_TIMEOUT_S}s)"
  agent TRIAGE-TASK.md triage.log "$TRIAGE_TIMEOUT_S" && trc=0 || trc=$?
  KIND=""
  if [ -f repo/triage.json ]; then
    mv repo/triage.json triage.json
    KIND=$(python3 -c 'import json; t=json.load(open("triage.json")); k=t.get("kind",""); print(k if k in ("api","lab","feature","elsewhere") else "")' 2>/dev/null || true)
  fi
  git -C repo checkout -q -- . && git -C repo clean -fdq   # the triage changes nothing in the tree
  if [ -z "$KIND" ]; then log "triage: no usable triage.json (agent exit $trc); the issue is treated as api"; rm -f triage.json; KIND=api
  else log "triage: $KIND: $(python3 -c 'import json; print(json.load(open("triage.json")).get("why",""))')"; fi
  case "$KIND" in
    lab)
      { echo "**Triage** (automated): this needs the lab, not the live build as it runs."; echo
        python3 -c 'import json; t=json.load(open("triage.json")); print(t.get("why","")); print(); print("What shows it:", t.get("repro","") or "(not stated)")'; } > COMMENT.md
      post_or_draft needs-lab; exit 0;;
    feature|elsewhere)
      { echo "**Triage** (automated): $KIND, nothing to reproduce on this lab."; echo; python3 -c 'import json; print(json.load(open("triage.json")).get("why",""))'; } > COMMENT.md
      post_or_draft out-of-scope; exit 0;;
  esac
  if [ "$TRIAGE_ONLY" = 1 ]; then finish triaged "(api: ready for the agent)"; exit 0; fi
fi

# the agent proper: reproduce on the live build, fix on the branch
render "$KIT/templates/ISSUE-TASK.md" > TASK.md
log "agent: $AGENT_CMD (timeout ${AGENT_TIMEOUT_S}s)"
agent TASK.md agent.log "$AGENT_TIMEOUT_S" && arc=0 || arc=$?
log "agent exit $arc ($(wc -l < agent.log) lines in agent.log)"

# what it left behind
fail() { finish failed "$*"; exit 2; }
[ -f repo/REPRO.md ] || fail "the agent wrote no REPRO.md (agent exit $arc)"
VERDICT=$(head -1 repo/REPRO.md | sed -n 's/^VERDICT: *\([a-z-]*\).*/\1/p')
case "$VERDICT" in reproduced|not-reproduced|unclear) ;; *) fail "REPRO.md does not start with a VERDICT line (got: $(head -1 repo/REPRO.md))";; esac
AGENT_VERDICT=$VERDICT; log "agent verdict: $VERDICT"
cp repo/REPRO.md REPRO.md; [ -f repo/PR.md ] && cp repo/PR.md PR.md
cd repo
git rm -q --cached REPRO.md PR.md 2>/dev/null && git commit -q -m "keep the agent's notes out of the tree" || true
cd ..

NOFIX=0
if [ "$VERDICT" = reproduced ]; then
  SCRIPT="tests/repro-issue-$N.sh"
  [ -f "repo/$SCRIPT" ] || fail "verdict reproduced, but repo/$SCRIPT is missing"
  FIX_COMMITS=$(git -C repo rev-list --count "$BASE_SHA..HEAD")
  if [ "$FIX_COMMITS" = 0 ]; then NOFIX=1; log "reproduced without a fix: nothing is committed on $BRANCH"
  else
    [ -f repo/PR.md ] && [ -n "$(head -1 repo/PR.md)" ] || fail "verdict reproduced with a fix, but PR.md (title line + body) is missing"
    git -C repo ls-files --error-unmatch "$SCRIPT" >/dev/null 2>&1 || fail "$SCRIPT is not committed"
  fi
  if [ "$LIVE_CHECK" = 1 ]; then
    # the confirmation: the live build (the base) must show the problem with the agent's own script
    set +e; ( cd repo && env -u GH_TOKEN -u GITHUB_TOKEN timeout 900 bash "$SCRIPT" "$LIVE_API" "$LIVE_MODEL" ) > live-repro.log 2>&1; lrc=$?; set -e   # no publishing credentials for a generated script
    LIVE_RC=$lrc; log "repro script against the live build: exit $lrc"
    if [ "$lrc" != 1 ]; then
      VERDICT=unclear
      if [ "$lrc" = 0 ]; then why="does not show it on the live build (exit 0)"; else why="errored on the live build (exit $lrc), so it judged nothing"; fi
      printf 'VERDICT: unclear\n\nThe agent reported the problem as reproduced, but its reproduction script %s. The agent'"'"'s notes follow.\n\n' "$why" > REPRO.md
      tail -n +2 repo/REPRO.md >> REPRO.md
    fi
  fi
fi

if [ "$VERDICT" = reproduced ] && [ "$NOFIX" = 0 ]; then
  TITLE=$(head -1 repo/PR.md)
  { tail -n +2 repo/PR.md; echo; echo "### Reproduction"; echo; tail -n +2 repo/REPRO.md; echo
    echo "Reproduction script: \`$SCRIPT\` (exits non-zero while the problem shows). The test pipeline runs it against the base and against this branch."
    if [ "$ISSUE_REPO" = "$REPO" ]; then echo; echo "Closes #$N"; else echo; echo "Issue: $ISSUE_URL"; fi
  } > body.md
  git -C repo push -q -u origin "$BRANCH"
  PR_URL=$(gh pr create -R "$REPO" --head "$BRANCH" --title "$TITLE" --body-file body.md --label "$PR_LABEL")
  finish pr "$PR_URL"; exit 0
fi

# reproduced without a fix, not reproduced, or unclear: the notes are the answer
if [ "$VERDICT" = reproduced ]; then
  { echo "**Reproduction** (automated, on the lab's live build \`$LIVE_MODEL\`): the problem shows; the script \`$SCRIPT\` confirms it (exit 1). No fix was produced."; echo; tail -n +2 REPRO.md; } > COMMENT.md
else
  { echo "**Reproduction attempt** (automated, on the lab's live build \`$LIVE_MODEL\`): verdict **$VERDICT**."; echo; tail -n +2 REPRO.md; } > COMMENT.md
fi
post_or_draft "$VERDICT"; exit 0
