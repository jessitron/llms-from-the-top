#!/usr/bin/env ruby

require "net/http"
require "json"

puts "Hi there, #{ENV['USER']}! I'm your handy dandy assistant, Vort!"
puts "What can I do for you today?"

loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"

  request = input
  response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/v1/completions"), request.to_json, {
    "content-type": "application/json"
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

