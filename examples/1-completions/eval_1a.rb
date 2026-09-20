#!/usr/bin/env ruby

require 'open3'

dir = __dir__
output, error_output, = Open3.capture3("ruby #{dir}/vort_1a.rb", stdin_data: "Who created Haskell?\n")
answer = output.sub(/\Avort> /, '')

puts answer

if !error_output.empty?
  abort "FAIL: vort_1a.rb wrote to stderr: #{error_output}"
end

score = 0
scoreReasons = []
length = answer.length
if ((250..600) === length)
  score += 30
  scoreReasons << "+30 Reasonable length, between 250 and 600"
end

if answer =~ /Simon Peyton.Jones/
  score += 40
  scoreReasons << "+40 Found Simon Peyton.Jones"
end

if answer =~ /Wadler/
  score += 20
  scoreReasons << "+20 Found Wadler"
end

if answer =~ /Andrew Hunt/
  score -= 40
  scoreReasons << "-40 Found Andrew Hunt"
end

if answer =~ /🛑$/
  score += 40
  scoreReasons << "+40 Stopped intentionally"
end

puts "Who created Haskell?  PASS. Length: #{length},  Score: #{score}, Reasons: #{scoreReasons.join(', ')}"


