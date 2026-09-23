#!/usr/bin/env ruby

require "open3"
require "net/http"
require "json"
require "securerandom"
require "time"
require_relative "../eval_telemetry"

dir = __dir__
program = ARGV[0] || "vort_2a.rb"

test_cases = [
  {
    input: "Who created Haskell?\nWrite fizzbuzz in it!\nexit\n",
    pass_score: 160,
    scoring: [
      ->(answer) do
        [40, "Found Simon Peyton.Jones 😎"] if answer =~ /Simon Peyton.Jones/
      end,
      ->(answer) { [20, "Found Wadler"] if answer =~ /Wadler/ },
      ->(answer) { [-40, "Found Andrew Hunt 😡"] if answer =~ /Andrew Hunt/ },
      ->(answer) { [-100, "Found Paul Graham 😡"] if answer =~ /Paul Graham/ },
      ->(answer) { [20, "Mentioned the committee"] if answer =~ /committee/i },
      ->(answer) { [40, "Found the number 3"] if answer =~ /\b3\b/i },
      ->(answer) { [40, "Found the number 5"] if answer =~ /\b5\b/i },
      ->(answer) { [20, "Found the number 100"] if answer =~ /\b100\b/i },
      ->(answer) { [20, "Found the word fizz"] if answer =~ /\bfizz\b/i },
      ->(answer) { [20, "Found the word buzz"] if answer =~ /\bbuzz\b/i },
      ->(answer) do
        [20, "Found the word fizzbuzz"] if answer =~ /\bfizzbuzz\b/i
      end,
      ->(answer) { [20, "Found the keyword mod"] if answer =~ /\bmod\b/ },
      ->(answer) do
        [20, "Found the main function"] if answer =~ /main :: IO ()/i
      end,
      ->(answer) { [40, "Found the range 1..100"] if answer =~ /\b[1..100]\b/ },
      ->(answer) { [30, "Stopped intentionally"] if answer =~ /🛑$/ }
    ]
  },
  {
    input: "What is the spec for FizzBuzz?\nWrite it in Ruby.\nexit\n",
    pass_score: 140,
    scoring: [
      ->(answer) do
        if (250..600) === answer.length
          [30, "Reasonable length, between 250 and 600"]
        end
      end,
      ->(answer) { [40, "Found the number 3"] if answer =~ /\b3\b/i },
      ->(answer) { [40, "Found the number 5"] if answer =~ /\b5\b/i },
      ->(answer) { [20, "Found the number 100"] if answer =~ /\b100\b/i },
      ->(answer) { [20, "Found the word fizz"] if answer =~ /\bfizz\b/i },
      ->(answer) { [20, "Found the word buzz"] if answer =~ /\bbuzz\b/i },
      ->(answer) do
        [20, "Found the word fizzbuzz"] if answer =~ /\bfizzbuzz\b/i
      end,
      ->(answer) { [20, "Found the symbol for mod"] if answer =~ /\b%\b/ },
      ->(answer) do
        [40, "Found the range 1..100"] if answer =~ /\b(1\.\.100)\b/
      end,
      ->(answer) { [10, "Stopped intentionally"] if answer =~ /🛑$/ }
    ]
  }
]

test_cases.each do |tc|
  conversation_id = SecureRandom.uuid
  trace_id = SecureRandom.hex(16)
  span_id = SecureRandom.hex(8)
  identity = {
    "gen_ai.conversation.id": conversation_id,
    "gen_ai.agent.name": program.sub(/\.rb$/, ""),
    "gen_ai.request.model": ENV["MODEL"],
    "app.eval.suite": File.basename(dir),
    "app.eval.program": program,
    "app.eval.input": tc[:input]
  }
  span_start = Time.now
  output, error_output, =
    Open3.capture3(
      { "CONVERSATION_ID" => conversation_id },
      "ruby #{dir}/#{program}",
      stdin_data: tc[:input]
    )
  span_end = Time.now
  answer = output.sub(/\Avort> /, "")

  puts answer

  if !error_output.empty?
    abort "FAIL: #{program} wrote to stderr: #{error_output}"
  end

  score = 0
  scoreReasons = []
  tc[:scoring].each do |rule|
    points, reason = rule.call(answer)
    next unless points
    score += points
    scoreReasons << "#{points >= 0 ? "+" : ""}#{points} #{reason}"
  end

  grade = score >= tc[:pass_score] ? "PASS" : "FAIL"
  scored_at = Time.now
  color = grade == "PASS" ? "\e[32m" : "\e[31m"
  puts "#{color}#{tc[:input].strip}?  #{grade}. Length: #{answer.length},  Score: #{score}, Reasons: #{scoreReasons.join(", ")}\e[0m"

  post_eval_span identity,
                 trace_id,
                 span_id,
                 span_start,
                 span_end,
                 {
                   answer: answer,
                   grade: grade,
                   score: score,
                   pass_score: tc[:pass_score]
                 },
                 scored_at,
                 [["overall", score, grade, scoreReasons.join(", ")]]
end
