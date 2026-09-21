## Honeycomb Gen AI message format (`gen_ai.input.messages` / `gen_ai.output.messages`)

For other attributes to add:
See Also: https://docs.honeycomb.io/send-data/use-cases/agents#enriching-your-traces-with-genai-context

When instrumenting LLM calls, set these two span attributes so Honeycomb's "Gen AI fields" tab
can render the conversation instead of showing "This span doesn't include message content."

Each attribute is a **JSON-encoded string** containing an **array of message objects**:

```json
[
  {
    "role": "user",
    "parts": [{ "type": "text", "content": "What's the weather in NYC?" }]
  },
  {
    "role": "assistant",
    "parts": [
      {
        "type": "tool_call",
        "id": "call_1",
        "name": "get_weather",
        "arguments": "{\"city\":\"NYC\"}"
      }
    ],
    "finish_reason": "tool_calls"
  }
]
```

### Rules

- **Top level must be a JSON array.** If it doesn't parse as an array of objects, Honeycomb
  falls back to showing the raw string instead of structured messages.
- **`role`**: `system` | `user` | `assistant` | `tool` (aliases `human`, `ai`, `model`, `function`
  are also accepted and normalized).
- **`parts`**: array of typed content parts, discriminated by `type`:
  | `type` | Fields | Used in |
  |---|---|---|
  | `text` | `content` (string) | input/output |
  | `tool_call` | `id`, `name`, `arguments` (string) | output |
  | `tool_call_response` | `id`, `response` (string) | input |
  | `reasoning` | `content` (string) | output |
  | `server_tool_call` | `id`, `name`, `server_tool_call` | output |
  | `server_tool_call_response` | `id`, `server_tool_call_response` | input |
  | `blob` | `modality`, `mime_type`, `content` (base64) | either |
  | `file` | `modality`, `mime_type`, `file_id` | either |
  | `uri` | `modality`, `mime_type`, `uri` | either |

  ⚠️ **The text part field is `content`, not `text`** — i.e. `{"type": "text", "content": "..."}`.
  This differs from some published examples (including the OTel Gen AI skill's own docs), which
  use `{"type": "text", "text": "..."}`. Using `text` instead of `content` will silently fail to
  render as a text part.

- **`content` (message-level, optional fallback)**: a plain string on the message itself, used
  only when `parts` is absent/empty. Works for simple `{role, content}` producers, but loses
  part-level rendering (tool calls, reasoning, etc.).
- **`finish_reason`** (optional): e.g. `"stop"`, `"tool_calls"`, `"length"`, `"content_filter"`.
- **`name`** (optional): participant name.
- Any other field on a message or part is preserved but shown as a collapsed "extra field" —
  it won't affect rendering of the recognized fields.
- **`gen_ai.system_instructions`** is a _separate_ attribute (array of parts, or a plain string)
  — Honeycomb folds it in as a synthesized leading `system` message if input/output don't
  already have one.
- **`gen_ai.tool.definitions`** is also a _separate_ attribute — the list of tools the model was
  given for this call (not part of `gen_ai.input.messages`). It's a JSON-encoded array shaped
  `{"type": "function", "name", "description", "parameters"}` — flattened, unlike OpenAI's
  request shape which nests `name`/`description`/`parameters` under a `function` key. Without
  this attribute Honeycomb has no tool schema to render alongside `tool_call` parts.
- Keep each attribute's JSON under a reasonable size — Honeycomb truncates content that's too
  large; truncate/redact on your end if messages can be large or sensitive.

### Raw copies for debugging translation

`src/router.js` also sets `app.raw_input_messages` / `app.raw_output_message`
alongside the `gen_ai.*` attributes — the untranslated messages/message
object, JSON-encoded, before conversion to the parts format above. If a
future shape isn't handled and collapses into a blank text part, these raw
attributes make that visible directly in Honeycomb, next to the translated
version.

### Minimal example (no tool calls)

```json
// gen_ai.input.messages
[{ "role": "user", "parts": [{ "type": "text", "content": "Summarize this doc." }] }]

// gen_ai.output.messages
[{ "role": "assistant", "parts": [{ "type": "text", "content": "Here's the summary..." }] }]
```
