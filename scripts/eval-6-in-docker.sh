#!/usr/bin/env bash
# Checks that the participant Docker image can run the whole stage-6 eval
# (git commits, vort_6c's OTel gems): builds ./Dockerfile, runs eval_6 inside it.
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -q -t llms-from-the-top-examples .
docker run --rm llms-from-the-top-examples ruby examples/6-subagents/test-changelog/eval_6.rb
