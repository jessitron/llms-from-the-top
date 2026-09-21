#!/usr/bin/env ruby

require 'net/http'
require 'json'
require 'securerandom'

CONVERSATION_ID = ENV["CONVERSATION_ID"] || SecureRandom.uuid

print 'vort> '
input = gets.chomp

request = { model: "base", prompt: input, max_tokens: 100 }
response = Net::HTTP.post URI('https://llms-from-the-top.jessitron.com/v1/completions'), request.to_json, {
  "content-type": 'application/json',
  "x-api-key": 'exploreddd',
  "user-agent": 'vort run by jessitron',
  "x-agent-name": 'vort_1a',
  "x-conversation-id": CONVERSATION_ID
}
case response
in Net::HTTPSuccess
  completion = JSON.parse(response.body)
  assistant_message = completion.dig('choices', 0, 'text')
  stop_reason = completion.dig('choices', 0, 'finish_reason')
  print assistant_message
  if stop_reason =~ /stop/
    puts "🛑"
  else
    puts "…"
  end
else
  warn "Error: #{response.code} #{response.message}", response.body
end
