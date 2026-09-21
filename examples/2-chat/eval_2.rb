#!/usr/bin/env ruby

require 'open3'
require 'net/http'
require 'json'

dir = __dir__
program = ARGV[0] || "vort_2a.rb"

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
  output, error_output, = Open3.capture3("ruby #{dir}/#{program}", stdin_data: tc[:input])
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
  color = grade == "PASS" ? "\e[32m" : "\e[31m"
  puts "#{color}#{tc[:input].strip}?  #{grade}. Length: #{answer.length},  Score: #{score}, Reasons: #{scoreReasons.join(', ')}\e[0m"

  Net::HTTP.post URI('https://api.honeycomb.io/1/events/llms-from-the-top-evals'), {
    program: program, model: ENV["MODEL"], input: tc[:input], answer: answer, grade: grade, score: score, pass_score: tc[:pass_score], reasons: scoreReasons.join(', '),
  }.to_json, { "content-type": 'application/json', "x-honeycomb-team": ENV['HONEYCOMB_API_KEY'] }
end
