#!/usr/bin/env ruby

require 'open3'

dir = __dir__
output, error_output, = Open3.capture3("ruby #{dir}/vort_1a.rb", stdin_data: "Who created Haskell?\n")
answer = output.sub(/\Avort> /, '')

puts answer

if !error_output.empty?
  abort "FAIL: vort_1a.rb wrote to stderr: #{error_output}"
end

length = answer.length
if !((250..600) === length)
  abort "FAIL: output length #{length} is not between 250 and 600 characters"
end

score = 0
if answer =~ /Simon Peyton.Jones/
  score += 40
end

if answer =~ /Wadler/
  score += 20
end

if answer =~ /Andrew Hunt/
  score -= 40
end

if answer =~ /🛑$/
  score += 40
end

puts "PASS. Length: #{length}, Score: #{score}"
