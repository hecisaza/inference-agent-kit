#!/usr/bin/env bash
# install-skill.sh: link the Claude Code skill into ~/.claude/skills and record where the kit lives.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$HOME/.claude/skills"
ln -sfn "$kit/skills/claude/inference-agent-work" "$HOME/.claude/skills/inference-agent-work"
echo "linked $HOME/.claude/skills/inference-agent-work -> $kit/skills/claude/inference-agent-work"
[[ -f "$kit/owner.yaml" ]] || echo "next: cp $kit/owner.example.yaml $kit/owner.yaml and edit it"
[[ -f "$kit/lab.yaml" ]] || echo "next: cp $kit/lab.example.yaml $kit/lab.yaml and edit it"
echo "set INFERENCE_AGENT_KIT=$kit in your shell profile if the kit is not at ~/inference-agent-kit"
