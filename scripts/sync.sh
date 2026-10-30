#!/usr/bin/env bash
# sync.sh OWNER/REPO [KEYWORD...]: stage 0 of AGENTS.md. Fetches the recipe's latest main, lists the patch numbers in
# use and the next free one, every open pull request with the patch files it adds or changes (and collisions between
# them), and open issues/PRs whose title matches a keyword. Read-only; needs git and an authenticated gh.
set -euo pipefail
[[ $# -ge 1 && "$1" == */* ]] || { echo "usage: $0 OWNER/REPO [KEYWORD...]" >&2; exit 2; }
REPO=$1; shift
CACHE=${SYNC_CACHE:-$HOME/.cache/inference-agent-kit/repos}
DIR="$CACHE/${REPO//\//__}"
mkdir -p "$CACHE"
if [[ -d "$DIR/.git" ]]; then git -C "$DIR" fetch -q origin; else git clone -q "https://github.com/$REPO.git" "$DIR"; fi
BR=$(git -C "$DIR" symbolic-ref -q --short refs/remotes/origin/HEAD | sed 's#^origin/##'); BR=${BR:-main}
echo "== $REPO $BR: $(git -C "$DIR" log -1 --format='%h %cs %s' "origin/$BR")"
echo
echo "== patches on $BR (zig/patches)"
nums=$(git -C "$DIR" ls-tree --name-only "origin/$BR" zig/patches/ 2>/dev/null | sed -n 's#.*/\([0-9]\{4\}\)-.*#\1#p' | sort -u)
if [[ -n "$nums" ]]; then
  echo "in use: $(echo "$nums" | head -3 | tr '\n' ' ')… $(echo "$nums" | tail -3 | tr '\n' ' ')($(echo "$nums" | wc -l) patches)"
  printf 'next free: %04d\n' $((10#$(echo "$nums" | tail -1) + 1))
else
  echo "(no zig/patches directory on $BR)"
fi
echo
echo "== open pull requests"
gh pr list -R "$REPO" --state open --limit 50 --json number,author,title,updatedAt,mergeable \
  -q '.[] | "#\(.number)\t\(.updatedAt[:10])\t\(.author.login)\t\(.mergeable)\t\(.title[:80])"' | column -t -s $'\t' || true
echo
echo "== patch files touched by open pull requests"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
for n in $(gh pr list -R "$REPO" --state open --limit 50 --json number -q '.[].number'); do
  gh pr view "$n" -R "$REPO" --json files -q '.files[].path' 2>/dev/null | sed -n 's#^zig/patches/\([0-9]\{4\}\)-\(.*\)#\1 \2#p' | while read -r num name; do
    printf '%s\t#%s\t%s\n' "$num" "$n" "$name"; done
done | sort > "$tmp"
if [[ -s "$tmp" ]]; then
  column -t -s $'\t' "$tmp"
  echo
  dup=$(cut -f1 "$tmp" | sort | uniq -d)
  for d in $dup; do echo "COLLISION: patch $d is added by $(awk -F'\t' -v d="$d" '$1==d{print $2}' "$tmp" | sort -u | tr '\n' ' ')"; done
  for d in $(cut -f1 "$tmp" | sort -u); do echo "$nums" | grep -qx "$d" && echo "NOTE: open PR changes or reuses $d, which is already on $BR: $(awk -F'\t' -v d="$d" '$1==d{print $2" "$3}' "$tmp" | sort -u | tr '\n' ' ')"; done
  true
else
  echo "(none)"
fi
if [[ $# -gt 0 ]]; then
  echo
  echo "== issues and PRs (any state) matching: $*"
  for k in "$@"; do
    gh search issues --repo "$REPO" "$k" --limit 10 --json number,state,title,updatedAt,isPullRequest \
      -q '.[] | "#\(.number)\t\(.state)\t\(if .isPullRequest then "PR" else "issue" end)\t\(.updatedAt[:10])\t\(.title[:80])"' 2>/dev/null
  done | sort -u -t$'\t' -k1,1 | column -t -s $'\t' || true
fi
