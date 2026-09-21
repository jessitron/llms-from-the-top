#!/usr/bin/env ruby

require 'pty'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'net/http'
require 'json'
require 'securerandom'

dir = __dir__
vort_dir = File.dirname(dir)
program = ARGV[0] || "vort_4d.rb"
workspace_dir = "#{dir}/workspace"
max_nudges = 5

test_cases = [
  {
    input: "Can you fix my program here? When it's fixed and markov.pl actually works, print 🎺 in your reply.",
    nudge: "Please just make markov.pl work.",
  },
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
  tmp_dir = Dir.mktmpdir("eval_4-")
  FileUtils.cp_r(Dir.glob("#{workspace_dir}/*"), tmp_dir)

  transcript = ""
  tool_call_count = 0
  turns = 0
  declared_done = false

  r, w, pid = PTY.spawn({ "CONVERSATION_ID" => conversation_id }, "ruby #{vort_dir}/#{program}", chdir: tmp_dir)
  r.set_encoding("UTF-8")
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

  eval_finish_reason = declared_done ? "declared_done" : "gave_up"

  markov_output, = Open3.capture2("perl markov.pl < shakespeare-sonnets.txt", chdir: tmp_dir)
  words = markov_output.split(/\s+/).reject(&:empty?)
  fixed = words.length == 50 && words.uniq.length > 1

  diff = fixed ? nil : Open3.capture2("diff", "-u", "#{workspace_dir}/markov.pl", "#{tmp_dir}/markov.pl").first

  grade = fixed ? "PASS" : "FAIL"
  color = grade == "PASS" ? "\e[32m" : "\e[31m"
  puts transcript
  puts "#{color}#{grade}. finish_reason=#{eval_finish_reason}, turns=#{turns}, tool_calls=#{tool_call_count}, markov_words=#{words.length}, unique_words=#{words.uniq.length}\e[0m"

  FileUtils.remove_entry(tmp_dir)

  Net::HTTP.post URI('https://api.honeycomb.io/1/events/llms-from-the-top-evals'), {
    "gen_ai.conversation.id": conversation_id, "gen_ai.request.model": ENV["MODEL"],
    program: program, grade: grade, eval_finish_reason: eval_finish_reason,
    turns: turns, tool_call_count: tool_call_count,
    markov_word_count: words.length, markov_unique_words: words.uniq.length,
    diff: diff,
  }.to_json, { "content-type": 'application/json', "x-honeycomb-team": ENV['HONEYCOMB_API_KEY'] }
end
