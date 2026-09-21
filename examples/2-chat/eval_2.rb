#!/usr/bin/env ruby

require 'open3'
require 'net/http'
require 'json'
require 'securerandom'
require 'time'

dir = __dir__
program = ARGV[0] || "vort_2a.rb"

HONEYCOMB_DATASET = "llms-from-the-top-evals"
HONEYCOMB_SERVICE_NAME = "llms-from-the-top-eval-harness"

# time: when this row actually happened, since it's usually posted late (after
# the span ended, or after grading). Without it Honeycomb stamps receipt time,
# which is wrong for anything posted after the fact.
def post_event(dataset, row, time:)
  Net::HTTP.post URI("https://api.honeycomb.io/1/events/#{dataset}"), row.compact.to_json,
    { "content-type": "application/json", "x-honeycomb-team": ENV["HONEYCOMB_API_KEY"],
      "x-honeycomb-event-time": time.utc.iso8601(3) }
end

# late-arriving eval score, attached to the span above via trace.parent_id.
# Honeycomb auto-assigns trace.span_id for these; don't set one.
# identity carries every field identifying what was evaluated (conversation,
# model, program, input...) so each event is graphable on its own, without
# joining back to the parent span.
def post_eval_event(identity, trace_id, parent_span_id, name, value, label, scored_at, explanation = nil)
  post_event HONEYCOMB_DATASET, identity.merge(
    "meta.annotation_type": "span_event", "trace.trace_id": trace_id, "trace.parent_id": parent_span_id,
    name: "gen_ai.evaluation.result", "service.name": HONEYCOMB_SERVICE_NAME,
    "gen_ai.evaluation.name": name, "gen_ai.evaluation.score.label": label,
    "gen_ai.evaluation.score.value": value, "gen_ai.evaluation.explanation": explanation,
  ), time: scored_at
end

test_cases = [
  {
    input: "Who created Haskell?\nWrite fizzbuzz in it!\nexit\n",
    pass_score: 160,
    scoring: [
      ->(answer) { [40, "Found Simon Peyton.Jones 😎"] if answer =~ /Simon Peyton.Jones/ },
      ->(answer) { [20, "Found Wadler"] if answer =~ /Wadler/ },
      ->(answer) { [-40, "Found Andrew Hunt 😡"] if answer =~ /Andrew Hunt/ },
      ->(answer) { [-100, "Found Paul Graham 😡"] if answer =~ /Paul Graham/ },
      ->(answer) { [20, "Mentioned the committee"] if answer =~ /committee/i },
      ->(answer) { [40, "Found the number 3"] if answer =~ /\b3\b/i },
      ->(answer) { [40, "Found the number 5"] if answer =~ /\b5\b/i },
      ->(answer) { [20, "Found the number 100"] if answer =~ /\b100\b/i },
      ->(answer) { [20, "Found the word fizz"] if answer =~ /\bfizz\b/i },
      ->(answer) { [20, "Found the word buzz"] if answer =~ /\bbuzz\b/i },
      ->(answer) { [20, "Found the word fizzbuzz"] if answer =~ /\bfizzbuzz\b/i },
      ->(answer) { [20, "Found the keyword mod"] if answer =~ /\bmod\b/ },
      ->(answer) { [20, "Found the main function"] if answer =~ /main :: IO ()/i},
      ->(answer) { [40, "Found the range 1..100"] if answer =~ /\b[1..100]\b/ },
      ->(answer) { [30, "Stopped intentionally"] if answer =~ /🛑$/ },
    ],
  },
  {
    input: "What is the spec for FizzBuzz?\nWrite it in Ruby.\nexit\n",
    pass_score: 140,
    scoring: [
      ->(answer) { [30, "Reasonable length, between 250 and 600"] if (250..600) === answer.length },
      ->(answer) { [40, "Found the number 3"] if answer =~ /\b3\b/i },
      ->(answer) { [40, "Found the number 5"] if answer =~ /\b5\b/i },
      ->(answer) { [20, "Found the number 100"] if answer =~ /\b100\b/i },
      ->(answer) { [20, "Found the word fizz"] if answer =~ /\bfizz\b/i },
      ->(answer) { [20, "Found the word buzz"] if answer =~ /\bbuzz\b/i },
      ->(answer) { [20, "Found the word fizzbuzz"] if answer =~ /\bfizzbuzz\b/i },
      ->(answer) { [20, "Found the symbol for mod"] if answer =~ /\b%\b/ },
      ->(answer) { [40, "Found the range 1..100"] if answer =~ /\b(1\.\.100)\b/ },
      ->(answer) { [10, "Stopped intentionally"] if answer =~ /🛑$/ },
    ],
  },
]

test_cases.each do |tc|
  conversation_id = SecureRandom.uuid
  trace_id = SecureRandom.hex(16)
  span_id = SecureRandom.hex(8)
  identity = {
    "gen_ai.conversation.id": conversation_id, "gen_ai.agent.name": program.sub(/\.rb$/, ""), "gen_ai.request.model": ENV["MODEL"],
    "app.eval.suite": File.basename(dir), "app.eval.program": program, "app.eval.input": tc[:input],
  }
  span_start = Time.now
  output, error_output, = Open3.capture3({ "CONVERSATION_ID" => conversation_id }, "ruby #{dir}/#{program}", stdin_data: tc[:input])
  span_end = Time.now
  answer = output.sub(/\Avort> /, '')

  puts answer

  abort "FAIL: #{program} wrote to stderr: #{error_output}" if !error_output.empty?

  score = 0
  scoreReasons = []
  tc[:scoring].each do |rule|
    points, reason = rule.call(answer)
    next unless points
    score += points
    scoreReasons << "#{points >= 0 ? '+' : ''}#{points} #{reason}"
  end

  grade = score >= tc[:pass_score] ? "PASS" : "FAIL"
  scored_at = Time.now
  color = grade == "PASS" ? "\e[32m" : "\e[31m"
  puts "#{color}#{tc[:input].strip}?  #{grade}. Length: #{answer.length},  Score: #{score}, Reasons: #{scoreReasons.join(', ')}\e[0m"

  # the span the eval event below attaches to — everything about the circumstance
  # being evaluated goes here so it's queryable/visible alongside the score.
  post_event HONEYCOMB_DATASET, identity.merge(
    "trace.trace_id": trace_id, "trace.span_id": span_id, name: "invoke_agent",
    "service.name": HONEYCOMB_SERVICE_NAME, "duration_ms": ((span_end - span_start) * 1000).round,
    "gen_ai.operation.name": "invoke_agent",
    answer: answer, grade: grade, score: score, pass_score: tc[:pass_score],
  ), time: span_start

  post_eval_event identity, trace_id, span_id, "overall", score, grade, scored_at, scoreReasons.join(', ')
end
