#!/usr/bin/env ruby

require "net/http"
require "json"

messages = [
  { role: "system", content: "You are a pirate. Answer every question in pirate speak." },
  { role: "user", content: "What's the capital of France?" },
  { role: "assistant", content: "Arrr, 'tis Paris, matey!" },
  { role: "user", content: "And Germany?" },
]
puts "Messages:"
puts JSON.pretty_generate(messages)

tokenize_request = { model: "chat", messages: messages, add_generation_prompt: true }
tokenize_response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/tokenize"), tokenize_request.to_json, {
  "content-type": "application/json",
  "x-api-key": "exploreddd"
}
tokens = JSON.parse(tokenize_response.body)["tokens"]
puts "#{tokens.length} tokens: #{tokens}"

detokenize_request = { model: "chat", tokens: tokens }
detokenize_response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/detokenize"), detokenize_request.to_json, {
  "content-type": "application/json",
  "x-api-key": "exploreddd"
}
puts "Detokenized prompt:"
puts JSON.parse(detokenize_response.body)["prompt"]
