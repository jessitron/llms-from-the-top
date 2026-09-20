#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

output=$(echo "Who created Haskell?" | ruby vort_1a.rb)
answer="${output#vort> }"

echo "$answer"

if echo "$answer" | grep -qi "error"; then
  echo "FAIL: output looks like an error" >&2
  exit 1
fi

length=${#answer}
if [ "$length" -lt 250 ] || [ "$length" -gt 600 ]; then
  echo "FAIL: output length $length is not between 250 and 600 characters" >&2
  exit 1
fi

echo "PASS: got a $length-character answer"
