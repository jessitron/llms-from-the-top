#!/usr/bin/env ruby

require "net/http"
require "json"
require "securerandom"

SYSTEM_PROMPT = "You are vort, a coding assistant. You are new to this and quickly admit when you don't know something. But you don't do other jobs; in fact you are rather insulted when asked to do work that is not coding.
  
You have some tools available to you, to take actions in this directory. You can only use one at a time, and you must reply in a format listed below, with no other text. Do not include the backticks.

You can list files! say `LISTFILES`

You can read a file! say `READFILE <filename>`
"

model = ENV["MODEL"] || "chat"

CONVERSATION_ID = ENV["CONVERSATION_ID"] || SecureRandom.uuid

messages = [ { role: "system", content: SYSTEM_PROMPT } ]
loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"
  
  loop do
    messages << {role: "user", content: input  }
    request = { model: model, messages: messages }
    response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/v1/chat/completions"), request.to_json, {
      "content-type": "application/json",
      "x-api-key": "exploreddd",
      "user-agent": "vort run by jessitron",
      "x-agent-name": "vort_4a",
      "x-conversation-id": CONVERSATION_ID
    }
    case response
    in Net::HTTPSuccess
      completion = JSON.parse(response.body)
      assistant_message = completion.dig("choices", 0, "message", "content")
      messages << {role: "assistant", content: assistant_message}
      puts "vort: #{assistant_message}"
      case assistant_message
      when /LISTFILES/
        files = Dir.children(".")
        input = files.join("\n")
        puts "  Listing files: #{files.join(", ")}"
      when /READFILE\s+(?<path>[A-Za-z0-9_\-\.\/]+)/m
        filename = $~[:path]
        if (File.exist?(filename))
          input = File.read(filename, encoding: "UTF-8")[0..2000]
          puts "  Reading file #{filename}: #{input.length} characters"
        else
          input = "File not found <#{filename}>"
          puts "  #{input}"
        end
      else
        break # read the next message from the user
      end
    else
      warn "Error: #{response.code} #{response.message}", response.body
      break
    end
  end
end
puts "Goodbye!"
