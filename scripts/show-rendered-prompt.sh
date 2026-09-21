#!/usr/bin/env bash
# Show that "messages" and "tools" are not magic: the server turns them into
# one string of tokens, which is all the model ever sees.
#
# Two views:
#   1. The chat template's output, via vLLM's /tokenize + /detokenize
#      (the same round-trip llm-api/otel_middleware.py does to record
#      gen_ai.prompt.rendered). Note that /detokenize drops special tokens,
#      so the raw token ids are printed too, with Mistral's control tokens
#      labelled.
#   2. What the `tools` array costs in prompt tokens, measured on the real
#      /v1/chat/completions endpoint: same messages, with and without tools.
#      /tokenize ignores `tools` in mistral tokenizer-mode, so this is the
#      only honest way to see that tool definitions are part of the prompt.
#
# Usage: scripts/show-rendered-prompt.sh
set -euo pipefail

BASE="${BASE:-https://llms-from-the-top.jessitron.com}"
API_KEY="${API_KEY:-exploreddd}"
MODEL="${MODEL:-better}"

SYSTEM="You are vort, a coding assistant."
USER="what files are here?"

TOOLS='[
  { "type": "function", "function": {
      "name": "list_files",
      "description": "List files in the current directory",
      "parameters": { "type": "object", "properties": {} } } },
  { "type": "function", "function": {
      "name": "read_file",
      "description": "Read a file'"'"'s contents",
      "parameters": { "type": "object",
        "properties": { "path": { "type": "string", "description": "path to the file" } },
        "required": ["path"] } } }
]'

post() {
  curl -sS "$BASE/$1" -H 'content-type: application/json' -H "x-api-key: $API_KEY" -d @-
}

messages() {
  jq -n --arg s "$SYSTEM" --arg u "$USER" \
    '[{role:"system",content:$s},{role:"user",content:$u}]'
}

echo "== 1. what the chat template makes of your messages =="
echo

tokenized=$(jq -n --arg m "$MODEL" --argjson msgs "$(messages)" \
  '{model:$m, messages:$msgs, add_generation_prompt:true}' | post tokenize)
tokens=$(echo "$tokenized" | jq -c '.tokens')

echo "token ids: $tokens"
echo
echo "         1 = <s>            (beginning of sequence)"
echo "     17/18 = [SYSTEM_PROMPT] ... [/SYSTEM_PROMPT]"
echo "       3/4 = [INST] ... [/INST]"
echo "   (Mistral control tokens; the rest are ordinary text.)"
echo
echo "detokenized -- special tokens are dropped on the way back to text:"
jq -n --arg m "$MODEL" --argjson t "$tokens" '{model:$m, tokens:$t}' \
  | post detokenize | jq -r '  "    " + .prompt'
echo

echo "== 2. what the tools array costs, in prompt tokens =="
echo

count_prompt_tokens() {
  post v1/chat/completions | jq -r '.usage.prompt_tokens // ("ERROR: " + (.|tostring))'
}

without=$(jq -n --arg m "$MODEL" --argjson msgs "$(messages)" \
  '{model:$m, max_tokens:1, messages:$msgs}' | count_prompt_tokens)
with=$(jq -n --arg m "$MODEL" --argjson msgs "$(messages)" --argjson tools "$TOOLS" \
  '{model:$m, max_tokens:1, messages:$msgs, tools:$tools}' | count_prompt_tokens)

echo "    without tools: $without prompt tokens"
echo "       with tools: $with prompt tokens"
echo
echo "The tool definitions are prompt. The model is still just reading text."
