#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

err=$(mktemp)
output=$(echo "Who created Haskell?" | ruby vort_1a.rb 2>"$err")
answer="${output#vort> }"
error_output=$(cat "$err")
rm -f "$err"

echo "$answer"

if [ -n "$error_output" ]; then
  echo "FAIL: vort_1a.rb wrote to stderr: $error_output" >&2
  exit 1
fi

length=${#answer}
if [ "$length" -lt 250 ] || [ "$length" -gt 600 ]; then
  echo "FAIL: output length $length is not between 250 and 600 characters" >&2
  exit 1
fi

echo "PASS: got a $length-character answer"
