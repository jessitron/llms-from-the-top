#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "json"
require "securerandom"

AGENTS_INSTRUCTION_FILE = "AGENTS.md"
MAX_FILE_READ = 2000

SYSTEM_PROMPT =
  "You are vort, a coding assistant. You are new to this and quickly admit when you don't know something. You read the documentation. You verify the results of your changes with tests. #{File.exist?(AGENTS_INSTRUCTION_FILE) ? File.read(AGENTS_INSTRUCTION_FILE) : ""}".freeze

CHANGELOG_SUBAGENT_PROMPT =
  "You are a subagent of vort. Your only job is to add one entry to CHANGELOG.md, following its existing format exactly. Do the task, don't ask questions, reply with your result when done.\n\n" +
    <<~SKILL
  Changelog entries in this project follow this format:

  `## YYYY.MM.DD <emoji> <lowercase past-tense summary, no period> — <component tag>`

  Emoji vocabulary:
  ✨ feature
  🐛 fix
  🔧 refactoring
  📝 docs
  ⚡ perf
  💥 breaking change

  A 💥 entry is always followed by an indented `migrate:` line explaining the upgrade, e.g.:

  ## 2024.02.01 💥 renamed --name positional arg to --name flag — greeter

      migrate: replace `greeter Alice` with `greeter --name Alice`

  New entries go at the top of the file, above the existing entries.
SKILL

COMMIT_SUBAGENT_PROMPT =
  "You are a subagent of vort. Your only job is to make one git commit with a message in this project's style. Do the task, don't ask questions, reply with your result when done.\n\n" +
    <<~SKILL
  Commit messages in this project follow this format:

  <risk level> <emoji> <lowercase imperative summary, no period>

  We divide all behaviors of the system into 3 sets. The change is intended to alter the Intended Change while not altering any of the Invariants. The Risk Levels are based on correctness guarantees: which invariants can this commit guarantee did not change, and can this commit guarantee that it changed the intended change in the way the authors intended?

  | Risk Level        | Code | Example                                    | Meaning                                | Correctness Guarantees                                |
  | ------------------ | ---- | ------------------------------------------- | --------------------------------------- | ------------------------------------------------------ |
  | (Proven) Safe      | `.`  | `. r Extract method`                        | Addresses all known and unknown risks.  | Intended Change, Known Invariants, Unknown Invariants  |
  | Validated          | `^`  | `^ r Extract method`                        | Addresses all known risks.              | Intended Change, Known Invariants                      |
  | Risky              | `!`  | `! r Extract method`                        | Some known risks remain unverified.     | Intended Change                                        |
  | (Probably) Broken  | `@`  | `@ r Start extracting method with no name`  | No risk attestation.                    |                                                         |

  Emoji vocabulary:
  ✨ feature
  🐛 fix
  🔧 refactoring
  📝 docs
  ⚡ perf
  💥 breaking change
SKILL

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
  {
    type: "function",
    function: {
      name: "write_changelog_entry",
      description:
        "Delegate to a subagent that adds one entry to CHANGELOG.md in this project's format. Give it a plain description of what changed.",
      parameters: {
        type: "object",
        properties: {
          description: {
            type: "string",
            description: "plain description of the change to record"
          }
        },
        required: ["description"]
      }
    }
  },
  {
    type: "function",
    function: {
      name: "make_commit",
      description:
        "Delegate to a subagent that makes one git commit with a message in this project's style. Give it a plain description of what to commit.",
      parameters: {
        type: "object",
        properties: {
          description: {
            type: "string",
            description: "plain description of what to commit"
          }
        },
        required: ["description"]
      }
    }
  }
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
                   "x-agent-name": "vort_6a",
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

CHANGELOG_TOOLS =
  TOOLS.select { |t| %w[read_file write_file].include?(t[:function][:name]) }
COMMIT_TOOLS =
  TOOLS.select { |t| %w[read_file run_command].include?(t[:function][:name]) }

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

CHANGELOG_HANDLERS = {
  "read_file" => READ_FILE,
  "write_file" => WRITE_FILE
}.freeze
COMMIT_HANDLERS = {
  "read_file" => READ_FILE,
  "run_command" => RUN_COMMAND
}.freeze

TOP_HANDLERS = {
  "list_files" => ->(_) { Dir.children(".").join("\n") },
  "read_file" => READ_FILE,
  "write_file" => WRITE_FILE,
  "run_command" => RUN_COMMAND,
  "write_changelog_entry" =>
    lambda do |args|
      run_subagent(
        CHANGELOG_SUBAGENT_PROMPT,
        CHANGELOG_TOOLS,
        CHANGELOG_HANDLERS,
        args["description"]
      )
    end,
  "make_commit" => ->(args) do
    run_subagent(
      COMMIT_SUBAGENT_PROMPT,
      COMMIT_TOOLS,
      COMMIT_HANDLERS,
      args["description"]
    )
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
