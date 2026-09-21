# llms-from-the-top/edge-proxy

This is normal backend code (unlike `../examples`), so normal engineering
practices apply — including tests.

## Running tests

```
cd edge-proxy
npm test
```

Runs `vitest run` against `src/router.test.js`.

## Adding tests

Business logic (auth, model routing, request validation, the
Anthropic-translation shape) lives in `src/router.js`, deliberately kept
free of any `@microlabs/otel-cf-workers` / `cloudflare:`-only imports. That's
what lets it run under plain Node with plain `vitest` — no Miniflare, no
`@cloudflare/vitest-pool-workers` — by mocking the global `fetch`.

`src/index.js` is just the Workers/OTel wiring (`instrument()`, span
processors, the baggage propagator) around `router.js`. It has no tests,
because it can't be loaded outside the Workers runtime — testing it would
mean pulling in the workerd/Miniflare-based test pool, which isn't worth it
for this workshop project.

So: if new logic belongs in the request/response handling — new routes, new
validation, new model behavior — put it in `router.js` and export it, and
add a test in `router.test.js`. If it's Workers/OTel plumbing (new span
processor, new propagator, new binding), it goes in `index.js` and stays
untested; keep it thin enough that reading it is enough.

Test pattern: `vi.stubGlobal("fetch", fetchMock)` in a `beforeEach`,
`vi.unstubAllGlobals()` in `afterEach`, assert on what `fetchMock` was
called with and/or what the returned `Response` looks like.
