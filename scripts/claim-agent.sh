#!/usr/bin/env bash
# claim-agent.sh RUN_DIR --pr-url URL [--out FILE] [--timeout S]
#
# The verify step: when a run ends SAFE, UNVERIFIED, an agent writes the claim test the suites lacked, from the pull
# request's diff and description, the second opinion (which names what would exercise the change) and the report. The
# agent works in RUN_DIR/claim/ with the task from templates/CLAIM-TASK.md, holds no token, and leaves claim.sh. This
# script then runs claim.sh against the live build (the base): it must print "CLAIM: does not hold" and exit 1 there,
# or the test does not isolate the change; the agent gets one correction round. The accepted script is copied to --out
# (default RUN_DIR/claim.sh) for the workflow to commit under claims/ and rerun the pipeline with it as the repro suite.
#
# Environment: AGENT_CMD (default: Claude Code headless), AGENT_TIMEOUT_S (default 1800), LIVE_API, LIVE_MODEL (required).
# Prints one RESULT: line: "RESULT: claim <file>" or "RESULT: no-claim <reason>". Exit 0 either way, 2 on a usage error.
set -uo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd); export KIT
run=${1:?usage: claim-agent.sh RUN_DIR --pr-url URL [--out FILE] [--timeout S]}; shift
pr_url=""; out=""; timeout_s=${AGENT_TIMEOUT_S:-1800}
while [ $# -gt 0 ]; do
  case "$1" in
    --pr-url) pr_url=$2; shift 2;; --out) out=$2; shift 2;; --timeout) timeout_s=$2; shift 2;;
    *) echo "unexpected argument $1" >&2; exit 2;;
  esac
done
: "${LIVE_API:?set LIVE_API (the OpenAI-compatible API of the live build)}"; : "${LIVE_MODEL:?set LIVE_MODEL}"
AGENT_CMD=${AGENT_CMD:-'claude -p --permission-mode acceptEdits --allowedTools "Bash,Read,Edit,Write,Glob,Grep"'}
out=${out:-$run/claim.sh}
log() { echo "$(date +%H:%M:%S) $*" | tee -a "$run/claim-log.txt"; }
done_() { log "RESULT: $*"; exit 0; }
b="$run/review"
[ -s "$b/pr.patch" ] && [ -s "$b/PR.md" ] || done_ "no-claim the review bundle ($b/pr.patch, PR.md) is missing"
w="$run/claim"; rm -rf "$w"; mkdir -p "$w"
cp "$b/pr.patch" "$b/PR.md" "$w/"; cp "$run/report.md" "$w/report.md" 2>/dev/null || true
cp "$run/REVIEW.md" "$w/REVIEW.md" 2>/dev/null || echo "(no second opinion was produced for this run)" > "$w/REVIEW.md"
cp "$KIT/suites/common.py" "$w/common.py"
sed -e "s#{{PR_URL}}#${pr_url:-the pull request}#g" -e "s#{{LIVE_API}}#$LIVE_API#g" -e "s#{{LIVE_MODEL}}#$LIVE_MODEL#g" -e "s#{{KIT}}#$KIT#g" \
  "$KIT/templates/CLAIM-TASK.md" > "$w/TASK.md"

run_agent() {  # $1: round
  log "agent round $1: $AGENT_CMD (timeout ${timeout_s}s)"
  ( cd "$w" && env -u GH_TOKEN -u GITHUB_TOKEN timeout "$timeout_s" bash -c "$AGENT_CMD" < TASK.md > "agent-round$1.log" 2>&1 ); local rc=$?
  log "agent exit $rc"
}
check_on_base() {  # the script must say the claim does not hold on the base, and exit 1
  [ -s "$w/claim.sh" ] || { verdict="no claim.sh written"; return 1; }
  bash -n "$w/claim.sh" 2>"$w/syntax.txt" || { verdict="claim.sh does not parse: $(head -1 "$w/syntax.txt")"; return 1; }
  ( cd "$w" && timeout 900 bash claim.sh "$LIVE_API" "$LIVE_MODEL" ) > "$w/base-run.txt" 2>&1; local rc=$?
  local line; line=$(grep -E "^CLAIM: " "$w/base-run.txt" | tail -1)
  if [ "$rc" = 1 ] && [ "$line" = "CLAIM: does not hold" ]; then verdict="ok"; return 0; fi
  if [ "$rc" = 0 ] && [ "$line" = "CLAIM: holds" ]; then verdict="the claim already holds on the base (exit 0): the test does not isolate the change"; return 1; fi
  verdict="on the base the script exited $rc with '${line:-no CLAIM line}' instead of 'CLAIM: does not hold' and exit 1"; return 1
}

verdict=""
run_agent 1
if ! check_on_base; then
  log "round 1: $verdict"
  { echo; echo "## Correction (round 2)"; echo; echo "Your first claim.sh was run against the base at $LIVE_API: $verdict."
    echo "Fix it so that on the base it prints 'CLAIM: does not hold' and exits 1, and on a build with the change it would print 'CLAIM: holds' and exit 0. Its output on the base follows."; echo
    echo '```'; tail -40 "$w/base-run.txt" 2>/dev/null; echo '```'; } >> "$w/TASK.md"
  run_agent 2
  check_on_base || done_ "no-claim after two rounds: $verdict"
fi
# nothing private may leave: an address or user@host in the script stops here
if grep -qE "([0-9]{1,3}\.){3}[0-9]{1,3}|[A-Za-z0-9_.-]+@[A-Za-z0-9.-]+" "$w/claim.sh"; then
  done_ "no-claim claim.sh contains an address or a user@host"
fi
cp "$w/claim.sh" "$out"; chmod +x "$out"
log "claim test accepted: on the base it says 'CLAIM: does not hold' (exit 1); $(wc -l < "$out") lines"
done_ "claim $out"
