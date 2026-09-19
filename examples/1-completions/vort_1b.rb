#!/usr/bin/env ruby

require 'net/http'
require 'json'

puts "What would you like to know?"

print 'vort> '
input = gets.chomp

request = { model: 'chat', prompt: "[INST] #{input} [/INST]" }
response = Net::HTTP.post URI('https://llms-from-the-top.jessitron.com/v1/completions'), request.to_json, {
  "content-type": 'application/json'
}
case response
in Net::HTTPSuccess
  completion = JSON.parse(response.body)
  assistant_message = completion.dig('choices', 0, 'text')
  puts assistant_message
else
  puts "Error: #{response.code} #{response.message}", response.body
end
