#!/usr/bin/env ruby

require 'open3'

dir = __dir__
output, = Open3.capture2("ruby #{dir}/vort_1a.rb", stdin_data: "Who created Haskell?\n")
answer = output.sub(/\Avort> /, '')

puts answer

if answer.match?(/error/i)
  abort "FAIL: output looks like an error"
end

length = answer.length
if length < 250 || length > 600
  abort "FAIL: output length #{length} is not between 250 and 600 characters"
end

puts "PASS: got a #{length}-character answer"
