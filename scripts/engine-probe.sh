#!/usr/bin/env bash
# engine-probe.sh --tree DIR --patch FILE [--probe DIR] [--zig ZIG] [--out DIR] [--template tool_call|dsml]
#
# Runs a directory of Zig probe tests against an engine source tree twice, without and with a patch, and compares
# what each kind of client receives. The default probes (probes/tensorfold-tools) are for TensorFold's server:
#   sig_test.zig     hand-written replies: calls, whole content, streamed text, any streamed step that takes text back
#   fuzz_test.zig    6000 random replies in three families, every tool-call markup the engine reads; per reply the
#                    whole reply's calls, the streamed text, and the calls a streaming client receives (the live
#                    streamer's, or the parsed calls when it streamed none, as the OpenAI route does)
#   parity_test.zig  hand-written streamed-versus-whole call parity cases
# Probes run as `zig test` in a safety-checked build, so an overflow or out-of-bounds slice the served (ReleaseFast)
# build would hide is a panic here: a probe that panics on the tree without the patch has found a bug that is already
# there. --tree is a checkout at the recipe's pin with the recipe's patches applied (and committed, so a checkout
# resets it); --patch is the change under test. Writes <probe>-base.txt and <probe>-patch.txt to --out and prints the
# summary (scripts/engine-probe-summary.py). Read-only on the lab: nothing here touches a server.
set -euo pipefail
KIT=$(cd "$(dirname "$0")/.." && pwd)
TREE=""; PATCH=""; PROBES="$KIT/probes/tensorfold-tools"; ZIG=${ZIG:-zig}; OUT=""; TEMPLATE=tool_call
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) TREE=$2; shift 2;; --patch) PATCH=$2; shift 2;; --probe) PROBES=$2; shift 2;; --zig) ZIG=$2; shift 2;;
    --out) OUT=$2; shift 2;; --template) TEMPLATE=$2; shift 2;; -h|--help) sed -n '2,18p' "$0"; exit 0;; *) echo "unknown argument $1" >&2; exit 1;;
  esac
done
[ -d "$TREE/zig/src/server" ] && [ -f "$PATCH" ] || { echo "usage: engine-probe.sh --tree DIR --patch FILE" >&2; exit 1; }
OUT=${OUT:-$(mktemp -d)}; mkdir -p "$OUT"
[ -z "$(git -C "$TREE" status --porcelain)" ] || { echo "$TREE has uncommitted changes; commit or reset them first" >&2; exit 1; }
run() {  # run SIDE: every probe on the tree as it is now
  for p in "$PROBES"/*_test.zig; do
    n=$(basename "$p" _test.zig); cp "$p" "$TREE/zig/src/server/"
    ( cd "$TREE" && timeout 3600 "$ZIG" test "zig/src/server/$(basename "$p")" 2>&1 ) | grep -oE "^(SIG|FUZZ|PARITY) .*|panic: .*|error: .*" > "$OUT/$n-$1.txt" || true
    rm -f "$TREE/zig/src/server/$(basename "$p")"
  done
}
run base
git -C "$TREE" apply "$PATCH"; run patch; git -C "$TREE" checkout -q -- . && git -C "$TREE" clean -fdq
python3 "$KIT/scripts/engine-probe-summary.py" "$OUT" --template "$TEMPLATE"
