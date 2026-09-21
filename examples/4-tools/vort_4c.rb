#!/usr/bin/env ruby

require "net/http"
require "json"

SYSTEM_PROMPT = "You are vort, a coding assistant. You are new to this and quickly admit when you don't know something. But you don't do other jobs; in fact you are rather insulted when asked to do work that is not coding."

TOOLS = [
  { type: "function", function: { name: "list_files", description: "List files in the current directory", parameters: { type: "object", properties: {} } } },
  { type: "function", function: { name: "read_file", description: "Read a file's contents", parameters: { type: "object", properties: { path: { type: "string", description: "path to the file" } }, required: ["path"] } } }
]

MODEL = ENV["MODEL"] || "haiku"
MAX_FILE_READ = 2000

messages = [ { role: "system", content: SYSTEM_PROMPT } ]
loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"
  messages << { role: "user", content: input }

  loop do
    request = { model: MODEL, messages: messages, tools: TOOLS }
    response = Net::HTTP.post URI("https://llms-from-the-top.jessitron.com/v1/chat/completions"), request.to_json, {
      "content-type": "application/json",
      "x-api-key": "exploreddd"
    }
    case response
    in Net::HTTPSuccess
      message = JSON.parse(response.body).dig("choices", 0, "message")
      messages << message
      tool_calls = message["tool_calls"]
      if tool_calls.nil? || tool_calls.empty?
        puts "vort: #{message["content"]}"
        break
      end
      tool_calls.each do |call|
        name = call.dig("function", "name")
        args = JSON.parse(call.dig("function", "arguments") || "{}")
        result = case name
        when "list_files"
          Dir.children(".").join("\n")
        when "read_file"
          File.exist?(args["path"]) ? File.read(args["path"], encoding: "UTF-8")[0..MAX_FILE_READ] : "File not found <#{args["path"]}>"
        end
        puts "  #{name}(#{args}) -> #{result[0..80]}"
        messages << { role: "tool", tool_call_id: call["id"], content: result }
      end
    else
      warn "Error: #{response.code} #{response.message}", response.body
      break
    end
  end
end
puts "Goodbye!"
