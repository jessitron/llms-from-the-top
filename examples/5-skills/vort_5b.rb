#!/usr/bin/env ruby

require "net/http"
require "json"
require "securerandom"

AGENTS_INSTRUCTION_FILE = "AGENTS.md"

SYSTEM_PROMPT = "You are vort, a coding assistant. You are new to this and quickly admit when you don't know something. You read the documentation. You verify the results of your changes with tests. #{File.exist?(AGENTS_INSTRUCTION_FILE) ? File.read(AGENTS_INSTRUCTION_FILE) : ""}"

SKILLS = [{ skill: "changelog", description: "Load this when creating a changelog entry", file: "skills/changelog.md"} ,
          { skill: "commit-message", description: "Load this when before you write a commit message", file: "skills/commit-message.md"}]
SKILL_TOOL_DESCRIPTION = "Available skills: " + SKILLS.map { |s| "#{s[:skill]} - #{s[:description]}" }.join(", ")

TOOLS = [
  { type: "function", function: { name: "list_files", description: "List files in the current directory", parameters: { type: "object", properties: {} } } },
  { type: "function", function: { name: "read_file", description: "Read a file's contents", parameters: { type: "object", properties: { path: { type: "string", description: "path to the file" } }, required: ["path"] } } },
  { type: "function", function: { name: "write_file", description: "Write content to a file", parameters: { type: "object", properties: { path: { type: "string", description: "path to the file" }, content: { type: "string", description: "content to write" } }, required: ["path", "content"] } } },
  { type: "function", function: { name: "run_command", description: "Run a shell command and get its output, e.g. to run tests", parameters: { type: "object", properties: { command: { type: "string", description: "the shell command to run" } }, required: ["command"] } } },
  { type: "function", function: { name: "load_skill", description: SKILL_TOOL_DESCRIPTION, parameters: { type: "object", properties: { skill: { type: "string", description: "the name of the skill to load" } }, required: ["skill"] } } }
]

HANDLERS = {
  "list_files" => ->(_) { Dir.children(".").join("\n") },
  "read_file" => ->(args) { File.exist?(args["path"]) ? File.read(args["path"], encoding: "UTF-8")[0..MAX_FILE_READ] : "File not found <#{args["path"]}>" },
  "write_file" => ->(args) { File.write(args["path"], args["content"]); "wrote #{args["content"].length} bytes to #{args["path"]}" },
  "run_command" => ->(args) { `#{args["command"]} 2>&1` },
  "load_skill" => ->(args) { File.read(SKILLS.find { |s| s[:skill] == args["skill"] }[:file], encoding: "UTF-8")[0..MAX_FILE_READ] }
}

MODEL = ENV["MODEL"] || "haiku"
MAX_FILE_READ = 2000

CONVERSATION_ID = ENV["CONVERSATION_ID"] || SecureRandom.uuid

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
      "x-api-key": "exploreddd",
      "x-agent-name": "vort_5b",
      "x-conversation-id": CONVERSATION_ID
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
        result = begin
          HANDLERS[name] ? HANDLERS[name].call(args) : "Unknown tool <#{name}>"
        rescue => e
          "Error: #{e.message}"
        end
        puts "  #{name}(#{args}) -> #{result[0..80].lines.map { |line| "  #{line}" }.join("")}"
        messages << { role: "tool", tool_call_id: call["id"], content: result }
      end
    else
      warn "Error: #{response.code} #{response.message}", response.body
      break
    end
  end
end
puts "Goodbye!"
