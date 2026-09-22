#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'securerandom'

print 'vort> '
input = gets.chomp

request = { model: "base", prompt: input, max_tokens: 100 }
response = Net::HTTP.post URI('https://llms-from-the-top.jessitron.com/v1/completions'), request.to_json, {
  "content-type": 'application/json',
  "x-api-key": 'exploreddd',
  "x-agent-name": 'vort_1a'
}
case response
in Net::HTTPSuccess
  completion = JSON.parse(response.body)
  assistant_message = completion.dig('choices', 0, 'text')
  finish_reason = completion.dig('choices', 0, 'finish_reason')
  print assistant_message
  if finish_reason =~ /stop/
    puts "🛑"
  else
    puts "…"
  end
else
  warn "Error: #{response.code} #{response.message}", response.body
end
