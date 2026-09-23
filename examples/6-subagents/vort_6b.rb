#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"

AGENTS_INSTRUCTION_FILE = "AGENTS.md"
MAX_FILE_READ = 2000
SUBAGENTS_DIR = "subagents"

SYSTEM_PROMPT =
  "You are vort, a coding assistant. You are new to this and quickly admit when you don't know something. You read the documentation. You verify the results of your changes with tests. #{File.exist?(AGENTS_INSTRUCTION_FILE) ? File.read(AGENTS_INSTRUCTION_FILE) : ""}".freeze

SUBAGENTS =
  Dir["#{SUBAGENTS_DIR}/*.md"].map do |file|
    header, body = File.read(file, encoding: "UTF-8").split("\n\n", 2)
    {
      name: File.basename(file, ".md"),
      description: header[/Description: (.*)/, 1],
      tool_names: header[/Tools: (.*)/, 1].split(",").map(&:strip),
      instructions: body
    }
  end.freeze

TOOLS = [
  {
    type: "function",
    function: {
      name: "list_files",
      description: "List files in the current directory",
      parameters: {
        type: "object",
        properties: {
        }
      }
    }
  },
  {
    type: "function",
    function: {
      name: "read_file",
      description: "Read a file's contents",
      parameters: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "path to the file"
          }
        },
        required: ["path"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "write_file",
      description: "Write content to a file",
      parameters: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "path to the file"
          },
          content: {
            type: "string",
            description: "content to write"
          }
        },
        required: %w[path content]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "run_command",
      description: "Run a shell command and get its output, e.g. to run tests",
      parameters: {
        type: "object",
        properties: {
          command: {
            type: "string",
            description: "the shell command to run"
          }
        },
        required: ["command"]
      }
    }
  },
  *SUBAGENTS.map do |sa|
    {
      type: "function",
      function: {
        name: sa[:name],
        description: sa[:description],
        parameters: {
          type: "object",
          properties: {
            description: {
              type: "string",
              description: "plain description of the task"
            }
          },
          required: ["description"]
        }
      }
    }
  end
].freeze

MODEL = ENV["MODEL"] || "haiku"

def call_model(messages, tools, conversation_id)
  request = { model: MODEL, messages: messages, tools: tools }
  Net::HTTP.post URI(
                   "https://llms-from-the-top.jessitron.com/v1/chat/completions"
                 ),
                 request.to_json,
                 {
                   "content-type": "application/json",
                   "x-api-key": "exploreddd",
                   "x-agent-name": "vort_6b",
                   "x-conversation-id": conversation_id
                 }
end

def run_conversation(messages, tools, handlers, conversation_id)
  loop do
    response = call_model(messages, tools, conversation_id)
    case response
    in Net::HTTPSuccess
      message = JSON.parse(response.body).dig("choices", 0, "message")
      messages << message
      tool_calls = message["tool_calls"]
      return message["content"] if tool_calls.nil? || tool_calls.empty?

      tool_calls.each do |call|
        name = call.dig("function", "name")
        args = JSON.parse(call.dig("function", "arguments") || "{}")
        result =
          begin
            if handlers[name]
              handlers[name].call(args)
            else
              "Unknown tool <#{name}>"
            end
          rescue StandardError => e
            "Error: #{e.message}"
          end
        puts "  #{name}(#{args}) -> #{result[0..80].lines.map { |line| "  #{line}" }.join("")}"
        messages << { role: "tool", tool_call_id: call["id"], content: result }
      end
    else
      warn "Error: #{response.code} #{response.message}", response.body
      return nil
    end
  end
end

def run_subagent(system_prompt, tools, handlers, task)
  puts "  forking subagent for: #{task}"
  run_conversation(
    [
      { role: "system", content: system_prompt },
      { role: "user", content: task }
    ],
    tools,
    handlers,
    SecureRandom.uuid
  )
end

READ_FILE =
  lambda do |args|
    if File.exist?(args["path"])
      File.read(args["path"], encoding: "UTF-8")[0..MAX_FILE_READ]
    else
      "File not found <#{args["path"]}>"
    end
  end
WRITE_FILE =
  lambda do |args|
    File.write(args["path"], args["content"])
    "wrote #{args["content"].length} bytes to #{args["path"]}"
  end
RUN_COMMAND = ->(args) { `#{args["command"]} 2>&1` }

BASE_HANDLERS = {
  "read_file" => READ_FILE,
  "write_file" => WRITE_FILE,
  "run_command" => RUN_COMMAND
}.freeze

TOP_HANDLERS = {
  "list_files" => ->(_) { Dir.children(".").join("\n") },
  **BASE_HANDLERS,
  **SUBAGENTS.to_h do |sa|
    subagent_tools = TOOLS.select { |t| sa[:tool_names].include?(t[:function][:name]) }
    subagent_handlers = BASE_HANDLERS.slice(*sa[:tool_names])
    subagent_prompt =
      "You are a subagent of vort. #{sa[:description]} Do the task, don't ask questions, reply with your result when done.\n\n#{sa[:instructions]}"
    [
      sa[:name],
      ->(args) do
        run_subagent(subagent_prompt, subagent_tools, subagent_handlers, args["description"])
      end
    ]
  end
}.freeze

conversation_id = ENV["CONVERSATION_ID"] || SecureRandom.uuid

messages = [{ role: "system", content: SYSTEM_PROMPT }]
loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"

  messages << { role: "user", content: input }
  puts "vort: #{run_conversation(messages, TOOLS, TOP_HANDLERS, conversation_id)}"
end
puts "Goodbye!"
