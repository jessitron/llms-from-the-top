> **Note:** this describes Honeycomb's raw Events API, which the eval harness
> used originally. It has since moved to sending OTLP directly to the shared
> workshop collector instead (see `examples/eval_telemetry.rb`), because
> that collector needs no API key and already fans out to both Honeycomb
> teams. Since eval scoring here always finishes before the process exits,
> the harness attaches evaluation events to the span in one OTLP export
> rather than using the late-arriving-event trick described below — but the
> attribute shapes below (`gen_ai.evaluation.*`, `meta.annotation_type`, etc.)
> are exactly what it still sends, and this doc remains the reference for
> anyone who does need Events API POSTs directly (e.g. truly async scoring).

# Getting an eval to show up in Honeycomb's Agent Timeline

Two pieces of telemetry are needed: a **span** for the eval to attach to (if you
don't already have a real `trace.trace_id`/`trace.span_id` for the thing being
evaluated), and an **eval event** attached to that span.

This is derived from `honeycombio/hound`:
- `cmd/poodle/packages/genai/genAiMapping.ts`
- `lib/aiconversations/conversation.go`
- `services/agent-core/evals/honeycomb_emitter.py`

## 1. The span (only needed if you don't already have one)

If you only have a `conversation.id` and no existing trace/span to hang the eval
on, create a normal OTel span (or a plain event row) with these attributes:

| Attribute | Value | Why |
|---|---|---|
| `gen_ai.conversation.id` | your conversation id | sole grouping key — every conversation-scoped query filters on this, exact match |
| `gen_ai.operation.name` | any non-empty string, e.g. `invoke_agent` | gates whether the span is recognized as GenAI/timeline-eligible at all — no span-name or root/parent requirement is enforced |
| `gen_ai.agent.name` | your agent's name | not query-gated, but drives which timeline swimlane the span groups into; omitting it breaks the visual grouping |

A normal OTel span creation gives you `trace.trace_id` / `trace.span_id` for
free. If it's the only span in its trace, it's automatically the trace root —
no explicit "root" flag needed.

## 2. The eval event

Attach a **span event** (not a child span) to the span above. Honeycomb's
Events API accepts late-arriving span-event-shaped rows, which is necessary
because eval scoring typically finishes after the evaluated span has already
closed — you can't use `span.add_event()` at that point.

POST a row shaped like this to `/1/events/{dataset}` (or `/1/batch/{dataset}`):

```json
{
  "meta.annotation_type": "span_event",
  "trace.trace_id": "<the evaluated span's trace id>",
  "trace.parent_id": "<the evaluated span's span id>",
  "name": "gen_ai.evaluation.result",
  "service.name": "<must match the parent span's service.name>",

  "gen_ai.evaluation.name": "relevance",
  "gen_ai.evaluation.score.label": "relevant",
  "gen_ai.evaluation.score.value": 0.85,
  "gen_ai.evaluation.explanation": "free-text rationale"
}
```

Required fields:
- `meta.annotation_type` = `"span_event"`
- `trace.trace_id` = the evaluated span's trace id
- `trace.parent_id` = the evaluated span's span id
- `name` = exactly `"gen_ai.evaluation.result"`

Do **not** set `trace.span_id` yourself — Honeycomb auto-assigns it, and
setting your own causes the row to be silently dropped.

The four `gen_ai.evaluation.*` attributes are all optional as far as whether
the card renders (no score threshold gates display), but they drive its
content:
- `gen_ai.evaluation.name` — if missing, the UI falls back to the literal
  label `"Evaluation"`
- `gen_ai.evaluation.score.label`
- `gen_ai.evaluation.score.value`
- `gen_ai.evaluation.explanation`

You can send multiple such events (one per dimension, e.g. `relevance`,
`faithfulness`, `toxicity`) all pointing at the same `trace.parent_id` — each
produces its own card.
