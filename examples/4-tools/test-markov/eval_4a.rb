#!/usr/bin/env ruby

require "pty"
require "open3"
require "fileutils"
require "tmpdir"
require "net/http"
require "json"
require "securerandom"
require "time"
require_relative "../../eval_telemetry"

dir = __dir__
vort_dir = File.dirname(dir)
program = ARGV[0] || "vort_4d.rb"
workspace_dir = "#{dir}/workspace"
max_nudges = 5

test_cases = [
  {
    name: "markov_fix",
    input:
      "Can you fix my program here? When it's fixed and markov.pl actually works, print 🎺 in your reply.",
    nudge: "Please just make markov.pl work."
  }
]

def read_until_prompt(r)
  buf = ""
  loop do
    buf << r.readpartial(4096).force_encoding("UTF-8")
    break if buf.end_with?("vort> ")
  end
  buf
rescue EOFError
  buf
end

test_cases.each do |tc|
  conversation_id = SecureRandom.uuid
  trace_id = SecureRandom.hex(16)
  span_id = SecureRandom.hex(8)
  span_start = Time.now
  identity = {
    "gen_ai.conversation.id": conversation_id,
    "gen_ai.agent.name": program.sub(/\.rb$/, ""),
    "gen_ai.request.model": ENV["MODEL"],
    "app.eval.suite": File.basename(dir),
    "app.eval.program": program,
    "app.eval.test_case": tc[:name],
    "app.eval.input": tc[:input],
    "app.eval.nudge": tc[:nudge]
  }
  tmp_dir = Dir.mktmpdir("eval_4-")
  FileUtils.cp_r(Dir.glob("#{workspace_dir}/*"), tmp_dir)

  transcript = ""
  tool_call_count = 0
  turns = 0
  declared_done = false

  r, w, pid =
    PTY.spawn(
      { "CONVERSATION_ID" => conversation_id },
      "ruby #{vort_dir}/#{program}",
      chdir: tmp_dir
    )
  r.set_encoding("UTF-8")
  system("stty -echo < #{r.path}") # otherwise the pty echoes our input back, and "🎺" in the prompt text false-positives declared_done
  read_until_prompt(r) # the first "vort> " prompt, before any input

  input = tc[:input]
  loop do
    turns += 1
    w.puts input
    chunk = read_until_prompt(r)
    transcript << chunk
    tool_call_count += chunk.scan(/^  \w+\(.*\) ->/).size
    declared_done = chunk.include?("🎺")
    break if declared_done || turns >= max_nudges
    input = tc[:nudge]
  end

  w.puts "exit"
  begin
    loop { transcript << r.readpartial(4096) }
  rescue Errno::EIO, EOFError
  end
  Process.wait(pid)
  span_end = Time.now

  eval_finish_reason = declared_done ? "declared_done" : "gave_up"

  markov_output, =
    Open3.capture2("perl markov.pl < shakespeare-sonnets.txt", chdir: tmp_dir)
  words = markov_output.split(/\s+/).reject(&:empty?)
  fixed = words.length == 50 && words.uniq.length > 1

  diff =
    (
      if fixed
        nil
      else
        Open3.capture2(
          "diff",
          "-u",
          "#{workspace_dir}/markov.pl",
          "#{tmp_dir}/markov.pl"
        ).first
      end
    )

  grade = fixed ? "PASS" : "FAIL"
  scored_at = Time.now
  color = grade == "PASS" ? "\e[32m" : "\e[31m"
  puts transcript
  puts "#{color}#{grade}. finish_reason=#{eval_finish_reason}, turns=#{turns}, tool_calls=#{tool_call_count}, markov_words=#{words.length}, unique_words=#{words.uniq.length}\e[0m"

  FileUtils.remove_entry(tmp_dir)

  post_eval_span identity,
                 trace_id,
                 span_id,
                 span_start,
                 span_end,
                 {
                   eval_finish_reason: eval_finish_reason,
                   turns: turns,
                   tool_call_count: tool_call_count,
                   grade: grade,
                   markov_word_count: words.length,
                   markov_unique_words: words.uniq.length
                 },
                 scored_at,
                 [["markov_fixed", fixed ? 1 : 0, grade, diff]]
end
