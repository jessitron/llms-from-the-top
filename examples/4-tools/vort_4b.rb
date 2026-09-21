#!/usr/bin/env ruby

require "net/http"
require "json"
require "securerandom"

SYSTEM_PROMPT = "You are vort, a coding assistant. You quickly admit when you don't know something. But you don't do other jobs; in fact you are rather insulted when asked to do work that is not coding."

TOOLS = [
  { type: "function", function:
    { name: "list_files",
      description: "List files in the current directory",
      parameters: { type: "object", properties: {} } 
    }
  },
  { type: "function", function:
    { name: "read_file",
      description: "Read a file's contents",
      parameters: { type: "object", properties: { path: { type: "string", description: "path to the file" } }, required: ["path"] } 
    }
  }
]

model = ENV["MODEL"] || "better"
MAX_FILE_READ = 4000
CONVERSATION_ID = ENV["CONVERSATION_ID"] || SecureRandom.uuid

messages = [ { role: "system", content: SYSTEM_PROMPT } ]
loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"

  loop do
    messages << { role: "user", content: input }
    request = { model: model, messages: messages, tools: TOOLS }
    response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/v1/chat/completions"), request.to_json, {
      "content-type": "application/json",
      "x-api-key": "exploreddd",
      "x-agent-name": "vort_4b",
      "x-conversation-id": CONVERSATION_ID
    }
    case response
    in Net::HTTPSuccess
      completion = JSON.parse(response.body)
      assistant_message = completion.dig("choices", 0, "message", "content")
      messages << { role: "assistant", content: assistant_message }
      puts "vort: #{assistant_message}"
      case assistant_message
      when /\[TOOL_CALLS\]list_files/
        result = Dir.children(".").join("\n")
      when /\[TOOL_CALLS\]read_file.*"path":\s*"(?<path>[^"]+)"/m
        filename = $~[:path]
        result = File.exist?(filename) ? File.read(filename, encoding: "UTF-8")[0..MAX_FILE_READ] : "File not found <#{filename}>"
      else
        break # read the next message from the user
      end
      puts "  -> #{result[0..80]}"
      input = "[TOOL_RESULTS]#{result}[/TOOL_RESULTS]"
    else
      warn "Error: #{response.code} #{response.message}", response.body
      break
    end
  end
end
puts "Goodbye!"
