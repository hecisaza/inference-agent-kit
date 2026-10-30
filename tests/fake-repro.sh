#!/usr/bin/env bash
# fake-repro.sh API MODEL: the self-test's "issue": the server answers 17*23 wrongly. Exit 1 while the problem shows, 0 when not.
r=$(curl -s -m 10 "$1/chat/completions" -H "content-type: application/json" \
  -d "{\"model\":\"$2\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 17*23? Reply with the number only.\"}],\"max_tokens\":8}")
echo "reply: $r"
grep -q '391' <<<"$r" && exit 0
echo "the reply is not 391: the problem shows"; exit 1
