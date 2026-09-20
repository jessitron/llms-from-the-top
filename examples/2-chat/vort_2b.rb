#!/usr/bin/env ruby

require "net/http"
require "json"

prompt = ""
loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"
  prompt += "[INST] #{input} [/INST]"

  request = { model: "chat", prompt: prompt }
  response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/v1/completions"), request.to_json, {
    "content-type": "application/json",
    "x-api-key": "exploreddd"
  }
  case response
  in Net::HTTPSuccess
    completion = JSON.parse(response.body)
    assistant_message = completion.dig("choices", 0, "text")
    prompt += "#{assistant_message}</s>"
    puts assistant_message
  else
    puts "Error: #{response.code} #{response.message}", response.body
  end
end
puts "Goodbye!"

