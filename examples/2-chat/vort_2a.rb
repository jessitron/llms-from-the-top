#!/usr/bin/env ruby

require "net/http"
require "json"
require "securerandom"

# a random uuid
CONVERSATION_ID = ENV["CONVERSATION_ID"] || SecureRandom.uuid
puts "Conversation ID: #{CONVERSATION_ID}"

loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"

  request = { model: "chat", prompt: "[INST] #{input} [/INST]" }
  response =
    Net::HTTP.post URI(
                     "https://llms-from-the-top.jessitron.com/v1/completions"
                   ),
                   request.to_json,
                   {
                     "content-type": "application/json",
                     "x-api-key": "exploreddd",
                     "x-agent-name": "vort_2a",
                     "x-conversation-id": CONVERSATION_ID
                   }
  case response
  in Net::HTTPSuccess
    completion = JSON.parse(response.body)
    assistant_message = completion.dig("choices", 0, "text")
    puts assistant_message
  else
    puts "Error: #{response.code} #{response.message}", response.body
  end
end
puts "Goodbye!"
