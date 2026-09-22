# Honeycomb query template: all spans for one conversation

Goal: given a `gen_ai.conversation.id`, pull every span that mentions it,
across all datasets in the `llms-from-the-top` environment (api,
edge-proxy, eval-harness, evals — a conversation's spans can land in more
than one).

## Column

`gen_ai.conversation.id` — present on `llms-from-the-top-api`,
`llms-from-the-top-edge-proxy`, `llms-from-the-top-eval-harness`,
`llms-from-the-top-evals`.

## The easy way: a query template URL

Honeycomb encodes the whole query spec as JSON in the `query` URL
parameter. A URL with no `/datasets/<slug>/` segment — just
`/environments/<env>?query=...` — runs environment-wide, across every
dataset. Paste this, replace `REPLACE_WITH_CONVERSATION_ID` with the
real id (plain find-and-replace works — a UUID has no characters that
need re-encoding), and open it:

```
https://ui.honeycomb.io/modernity/environments/llms-from-the-top?query=%7B%22time_range%22%3A604800%2C%22granularity%22%3A0%2C%22breakdowns%22%3A%5B%5D%2C%22calculations%22%3A%5B%7B%22op%22%3A%22COUNT%22%7D%5D%2C%22filters%22%3A%5B%7B%22column%22%3A%22gen_ai.conversation.id%22%2C%22op%22%3A%22%3D%22%2C%22value%22%3A%22REPLACE_WITH_CONVERSATION_ID%22%7D%5D%2C%22filter_combination%22%3A%22AND%22%2C%22orders%22%3A%5B%7B%22op%22%3A%22COUNT%22%2C%22order%22%3A%22descending%22%7D%5D%2C%22limit%22%3A1000%7D
```

That decodes to:

```json
{
  "time_range": 604800,
  "granularity": 0,
  "breakdowns": [],
  "calculations": [{"op": "COUNT"}],
  "filters": [
    {"column": "gen_ai.conversation.id", "op": "=", "value": "REPLACE_WITH_CONVERSATION_ID"}
  ],
  "filter_combination": "AND",
  "orders": [{"op": "COUNT", "order": "descending"}],
  "limit": 1000
}
```

`time_range` is in seconds (604800 = 7 days) — widen it if the
conversation is older. Once it's open, add breakdowns/columns or switch
to the Trace view on a result to see the spans themselves; the filter is
the part that matters and it's already scoped to all datasets.

## Via the Honeycomb MCP (`honeycomb-modernity`)

Same idea, for when you'd rather have an agent run it and read back the
raw rows instead of opening a browser:

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
(`a6c27606-dedb-4f1e-9006-fff09bc5d26e`) — both the URL template and the
MCP form returned the same 46 spans, all from
`llms-from-the-top-edge-proxy`, correctly scoped environment-wide.
