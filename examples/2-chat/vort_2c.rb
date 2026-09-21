#!/usr/bin/env ruby

require "net/http"
require "json"

messages = []
loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"
  messages << {role: "user", content: input  }

  request = { model: "better", messages: messages }
  response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/v1/chat/completions"), request.to_json, {
    "content-type": "application/json",
    "x-api-key": "exploreddd"
  }
  case response
  in Net::HTTPSuccess
    completion = JSON.parse(response.body)
    assistant_message = completion.dig("choices", 0, "message", "content")
    messages << {role: "assistant", content: assistant_message}
    puts assistant_message
  else
    puts "Error: #{response.code} #{response.message}", response.body
  end
end
puts "Goodbye!"
