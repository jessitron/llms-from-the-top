require "net/http"
require "json"

# this collector routes each OTLP resource straight into a Honeycomb dataset
# named after service.name (same as edge-proxy and llm-api's datasets do) —
# so this has to stay "llms-from-the-top-evals" to land in the same dataset
# eval data has always lived in, not the eval-harness's own service identity.
HONEYCOMB_SERVICE_NAME = "llms-from-the-top-evals"

# same public OTel collector edge-proxy and llm-api already export to (see
# edge-proxy/src/index.js, llm-api/app.py) — it fans out to both Honeycomb
# teams on its own, and needs no API key here, so an eval run from anyone's
# machine (not just Jess's) shows up in Honeycomb.
OTLP_TRACES_ENDPOINT = "https://workshop.jessitron.honeydemo.io/v1/traces"

def otlp_value(v)
  case v
  when true, false
    { boolValue: v }
  when Integer
    { intValue: v.to_s }
  when Float
    { doubleValue: v }
  else
    { stringValue: v.to_s }
  end
end

def otlp_attrs(hash)
  hash.compact.map { |k, v| { key: k.to_s, value: otlp_value(v) } }
end

def nanos(time)
  (time.to_r * 1_000_000_000).to_i.to_s
end

# posts the span for the thing being evaluated, with its eval-score events
# attached directly as OTel span events. Scoring here always finishes before
# the process exits, so — unlike Honeycomb's Events API, which needs a
# separate late-arriving-event trick (see notes/eval-telemetry-requirements.md)
# — one span export carries the whole eval result in a single request.
# `evaluations` is an array of [name, value, label, explanation] score rows.
def post_eval_span(
  identity,
  trace_id,
  span_id,
  start_time,
  end_time,
  span_attrs,
  scored_at,
  evaluations
)
  events =
    evaluations.map do |name, value, label, explanation|
      {
        timeUnixNano: nanos(scored_at),
        name: "gen_ai.evaluation.result",
        attributes:
          otlp_attrs(
            identity.merge(
              "gen_ai.evaluation.name": name,
              "gen_ai.evaluation.score.label": label,
              "gen_ai.evaluation.score.value": value,
              "gen_ai.evaluation.explanation": explanation
            )
          )
      }
    end
  span = {
    traceId: trace_id,
    spanId: span_id,
    name: "invoke_agent",
    kind: 1,
    startTimeUnixNano: nanos(start_time),
    endTimeUnixNano: nanos(end_time),
    attributes:
      otlp_attrs(
        identity.merge("gen_ai.operation.name": "invoke_agent").merge(
          span_attrs
        )
      ),
    events: events
  }
  body = {
    resourceSpans: [
      {
        resource: {
          attributes: otlp_attrs("service.name": HONEYCOMB_SERVICE_NAME)
        },
        scopeSpans: [{ spans: [span] }]
      }
    ]
  }
  Net::HTTP.post URI(OTLP_TRACES_ENDPOINT),
                 body.to_json,
                 { "content-type": "application/json" }
end

# same link format edge-proxy puts on every chat response (see traceLink in
# edge-proxy/src/router.js): Honeycomb's open sandbox, where anyone can open
# a trace without logging in. The collector fans out there too, so the eval
# span shows up in the workshop environment's llms-from-the-top-evals dataset.
# trace_start_ts/trace_end_ts only need to bound the search window.
def trace_link(trace_id, span_id, start_time, end_time)
  params =
    URI.encode_www_form(
      trace_id: trace_id,
      span: span_id,
      trace_start_ts: start_time.to_i - 60,
      trace_end_ts: end_time.to_i + 60
    )
  "https://play.honeycomb.io/sandbox/environments/workshop/datasets/#{HONEYCOMB_SERVICE_NAME}/trace?#{params}"
end
