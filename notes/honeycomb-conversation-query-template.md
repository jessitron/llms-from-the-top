# Honeycomb query template: all spans for one conversation

Goal: given a `gen_ai.conversation.id`, pull every span that mentions it,
across all datasets in the `llms-from-the-top` environment (api,
edge-proxy, eval-harness, evals — a conversation's spans can land in more
than one).

## Column

`gen_ai.conversation.id` — present on `llms-from-the-top-api`,
`llms-from-the-top-edge-proxy`, `llms-from-the-top-eval-harness`,
`llms-from-the-top-evals`.

## Via the Honeycomb UI

1. Go to the `llms-from-the-top` environment (not a specific dataset —
   pick **All Datasets** at the dataset selector, top left).
2. New query: filter `gen_ai.conversation.id` = `<paste the id>`.
3. Add columns you want as a table (Visualize: none, or add a COUNT if
   you just want to confirm it matches something), or switch to "Trace"
   view on one of the resulting traces to see the whole conversation's
   spans in context.
4. Save this as a Board/query template once, then just edit the filter
   value each time — Honeycomb keeps the rest of the shape.

Bookmark-able version, environment-wide (no dataset in the path):
`https://ui.honeycomb.io/modernity/environments/llms-from-the-top/result/<query_run_id>`
— every `run_query` call below returns a fresh one of these in
`query_url`; there's no static "fill in the id" URL because Honeycomb
mints a new query_run_id per run.

## Via the Honeycomb MCP (`honeycomb-modernity`)

```json
{
  "team": "modernity",
  "environment_slug": "llms-from-the-top",
  "environment_wide_query": true,
  "query_spec": {
    "filters": [
      {"column": "gen_ai.conversation.id", "op": "=", "value": "<conversation_id>"}
    ],
    "from": "-7d"
  },
  "raw_row_columns": ["service.name", "name", "gen_ai.conversation.id", "trace.trace_id", "trace.span_id", "duration_ms"]
}
```

Swap `raw_row_columns` for whatever you're actually looking at (e.g. add
`gen_ai.request.model`, `error`, `exception.message`). `environment_wide_query: true` replaces `dataset_slug` — that's
what makes it search every dataset in the environment instead of one.

Verified 2026-09-22 against a real conversation id
(`a6c27606-dedb-4f1e-9006-fff09bc5d26e`) — returned 46 spans, all from
`llms-from-the-top-edge-proxy`, correctly scoped environment-wide.
