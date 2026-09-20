#!/usr/bin/env ruby

require 'open3'

dir = __dir__

test_cases = [
  {
    program: "vort_1a.rb",
    input: "Who created Haskell?\n",
    pass_score: 50,
    scoring: [
      ->(answer) { [30, "Reasonable length, between 250 and 600"] if (250..600) === answer.length },
      ->(answer) { [40, "Found Simon Peyton.Jones 😎"] if answer =~ /Simon Peyton.Jones/ },
      ->(answer) { [20, "Found Wadler"] if answer =~ /Wadler/ },
      ->(answer) { [-40, "Found Andrew Hunt 😡"] if answer =~ /Andrew Hunt/ },
      ->(answer) { [10, "Stopped intentionally"] if answer =~ /🛑$/ },
    ],
  },
  {
    program: "vort_1a.rb",
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
  output, error_output, = Open3.capture3("ruby #{dir}/#{tc[:program]}", stdin_data: tc[:input])
  answer = output.sub(/\Avort> /, '')

  puts answer

  abort "FAIL: #{tc[:program]} wrote to stderr: #{error_output}" if !error_output.empty?

  score = 0
  scoreReasons = []
  tc[:scoring].each do |rule|
    points, reason = rule.call(answer)
    next unless points
    score += points
    scoreReasons << "#{points >= 0 ? '+' : ''}#{points} #{reason}"
  end

  grade = score >= tc[:pass_score] ? "PASS" : "FAIL"
  puts "#{tc[:input].strip}?  #{grade}. Length: #{answer.length},  Score: #{score}, Reasons: #{scoreReasons.join(', ')}"
end
