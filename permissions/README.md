# Suggested permissions

Agents stall when a routine lab step needs a permission prompt or is blocked by an automatic classifier. These are the
steps this kit runs often. Grant only what you are comfortable with; everything public (push, PR, comment, post) should
stay behind an explicit question in any case.

## Claude Code

Merge into your settings (`~/.claude/settings.json` or the project's `.claude/settings.json`), replacing the host
addresses with your own (`lab.yaml`):

```json
{
  "permissions": {
    "allow": [
      "Bash(scripts/sync.sh:*)",
      "Bash(scripts/canary.py:*)",
      "Bash(scripts/pairtest plan:*)",
      "Bash(codex exec:*)",
      "Bash(ssh me@192.0.2.11:*)",
      "Bash(ssh me@192.0.2.12:*)",
      "Bash(ssh me@192.0.2.13:*)",
      "Bash(ssh me@192.0.2.14:*)"
    ],
    "ask": [
      "Bash(scripts/pairtest run:*)",
      "Bash(scripts/pairtest restore:*)",
      "Bash(git push:*)",
      "Bash(gh pr create:*)",
      "Bash(gh pr comment:*)",
      "Bash(gh repo fork:*)"
    ]
  }
}
```

`pairtest run` and `restore` stop and start a served model, so they stay in `ask` unless you have agreed a window.

## Codex

Codex reads `AGENTS.md` natively. When Codex is the *reviewer* (`scripts/review.sh run`), the read-only rule is stated
in the task text itself, because sandbox flags such as `-s read-only` do not work on every host.

## Grok and others

Point the agent at `AGENTS.md` (most agents read it from the working directory). Keep the same allow/ask split.
