#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"
require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "opentelemetry-sdk"
  gem "opentelemetry-exporter-otlp"
end

ENV["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ||= "https://workshop.jessitron.honeydemo.io/v1/traces"
OpenTelemetry::SDK.configure { |c| c.service_name = "vort" }
TRACER = OpenTelemetry.tracer_provider.tracer("vort_6c")

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

def call_model(messages, tools, conversation_id, agent_name)
  request = { model: MODEL, messages: messages, tools: tools }
  headers = {}
  OpenTelemetry.propagation.inject(headers)
  Net::HTTP.post URI(
                   "https://llms-from-the-top.jessitron.com/v1/chat/completions"
                 ),
                 request.to_json,
                 {
                   "content-type": "application/json",
                   "x-api-key": "exploreddd",
                   "x-agent-name": agent_name,
                   "x-conversation-id": conversation_id,
                   **headers
                 }
end

def run_conversation(messages, tools, handlers, conversation_id, agent_name)
  TRACER.in_span(
    "invoke_agent #{agent_name}",
    attributes: {
      "gen_ai.operation.name" => "invoke_agent",
      "gen_ai.agent.name" => agent_name,
      "gen_ai.conversation.id" => conversation_id,
      "gen_ai.request.model" => MODEL,
      "gen_ai.system_instructions" => [{ type: "text", content: messages.first[:content] }].to_json,
      "gen_ai.input.messages" => [{ role: "user", parts: [{ type: "text", content: messages.last[:content] }] }].to_json,
      "gen_ai.tool.definitions" => tools.map { |t| { type: "function", **t[:function] } }.to_json
    }
  ) do |agent_span|
    loop do
      response = call_model(messages, tools, conversation_id, agent_name)
      case response
      in Net::HTTPSuccess
        message = JSON.parse(response.body).dig("choices", 0, "message")
        messages << message
        tool_calls = message["tool_calls"]
        if tool_calls.nil? || tool_calls.empty?
          agent_span.set_attribute("gen_ai.output.messages", [{ role: "assistant", parts: [{ type: "text", content: message["content"] }], finish_reason: "stop" }].to_json)
          return message["content"]
        end

        tool_calls.each do |call|
          name = call.dig("function", "name")
          args = JSON.parse(call.dig("function", "arguments") || "{}")
          result =
            TRACER.in_span(
              "execute_tool #{name}",
              attributes: {
                "gen_ai.operation.name" => "execute_tool",
                "gen_ai.tool.name" => name,
                "gen_ai.tool.type" => "function",
                "gen_ai.tool.call.id" => call["id"],
                "gen_ai.tool.call.arguments" => args.to_json,
                "gen_ai.agent.name" => agent_name,
                "gen_ai.conversation.id" => conversation_id
              }
            ) do |tool_span|
              result =
                begin
                  if handlers[name]
                    handlers[name].call(args)
                  else
                    tool_span.set_attribute("error.type", "unknown_tool")
                    "Unknown tool <#{name}>"
                  end
                rescue StandardError => e
                  tool_span.set_attribute("error.type", e.class.name)
                  tool_span.status = OpenTelemetry::Trace::Status.error(e.message)
                  "Error: #{e.message}"
                end
              tool_span.set_attribute("gen_ai.tool.call.result", result.to_s)
              result
            end
          puts "  #{name}(#{args}) -> #{result[0..80].lines.map { |line| "  #{line}" }.join("")}"
          messages << { role: "tool", tool_call_id: call["id"], content: result }
        end
      else
        warn "Error: #{response.code} #{response.message}", response.body
        agent_span.set_attribute("error.type", response.code)
        agent_span.status = OpenTelemetry::Trace::Status.error("#{response.code} #{response.message}")
        return nil
      end
    end
  end
end

def run_subagent(system_prompt, tools, handlers, task, name, conversation_id)
  puts "  forking subagent for: #{task}"
  run_conversation(
    [
      { role: "system", content: system_prompt },
      { role: "user", content: task }
    ],
    tools,
    handlers,
    conversation_id,
    name
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

CONVERSATION_ID = ENV["CONVERSATION_ID"] || SecureRandom.uuid

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
        run_subagent(subagent_prompt, subagent_tools, subagent_handlers, args["description"], sa[:name], CONVERSATION_ID)
      end
    ]
  end
}.freeze

messages = [{ role: "system", content: SYSTEM_PROMPT }]
loop do
  print "vort> "
  input = gets.chomp
  break if input in "exit" | "quit"

  messages << { role: "user", content: input }
  puts "vort: #{run_conversation(messages, TOOLS, TOP_HANDLERS, CONVERSATION_ID, "vort_6c")}"
  OpenTelemetry.tracer_provider.force_flush
end
OpenTelemetry.tracer_provider.shutdown
puts "Goodbye!"
