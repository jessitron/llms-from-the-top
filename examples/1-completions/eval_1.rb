#!/usr/bin/env ruby

require 'open3'
require 'net/http'
require 'json'
require 'securerandom'
require 'time'
require_relative '../eval_telemetry'

dir = __dir__
program = ARGV[0] || "vort_1a.rb"

test_cases = [
  {
    input: "Who created Haskell?\n",
    pass_score: 50,
    scoring: [
      ->(answer) { [30, "Reasonable length, between 250 and 600"] if (250..600) === answer.length },
      ->(answer) { [40, "Found Simon Peyton.Jones 😎"] if answer =~ /Simon Peyton.Jones/ },
      ->(answer) { [20, "Found Wadler"] if answer =~ /Wadler/ },
      ->(answer) { [-40, "Found Andrew Hunt 😡"] if answer =~ /Andrew Hunt/ },
      ->(answer) { [20, "Mentioned the committee"] if answer =~ /committee/i },
      ->(answer) { [10, "Stopped intentionally"] if answer =~ /🛑$/ },
    ],
  },
  {
    input: "Write fizzbuzz in Ruby\n",
    pass_score: 80,
    scoring: [
      ->(answer) { [30, "Reasonable length, between 250 and 600"] if (250..600) === answer.length },
      ->(answer) { [40, "Found the number 3"] if answer =~ /\b3\b/i },
      ->(answer) { [40, "Found the number 5"] if answer =~ /\b5\b/i },
      ->(answer) { [40, "Found the number 100"] if answer =~ /\b100\b/i },
      ->(answer) { [10, "Stopped intentionally"] if answer =~ /🛑$/ },
    ],
  },
]

test_cases.each do |tc|
  conversation_id = SecureRandom.uuid
  trace_id = SecureRandom.hex(16)
  span_id = SecureRandom.hex(8)
  identity = {
    "gen_ai.conversation.id": conversation_id, "gen_ai.agent.name": program.sub(/\.rb$/, ""),
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

  post_eval_span identity, trace_id, span_id, span_start, span_end,
    { answer: answer, grade: grade, score: score, pass_score: tc[:pass_score] }, scored_at,
    [["overall", score, grade, scoreReasons.join(', ')]]
end
