#!/usr/bin/env ruby

require 'pty'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'net/http'
require 'json'
require 'securerandom'
require 'time'

dir = __dir__
vort_dir = File.dirname(dir)
program = ARGV[0] || "vort_4d.rb"
workspace_dir = "#{dir}/workspace"
max_nudges = 5

HONEYCOMB_DATASET = "llms-from-the-top-evals"
HONEYCOMB_SERVICE_NAME = "llms-from-the-top-eval-harness"

# time: when this row actually happened, since it's usually posted late (after
# the span ended, or after grading). Without it Honeycomb stamps receipt time,
# which is wrong for anything posted after the fact.
def post_event(dataset, row, time:)
  Net::HTTP.post URI("https://api.honeycomb.io/1/events/#{dataset}"), row.compact.to_json,
    { "content-type": "application/json", "x-honeycomb-team": ENV["HONEYCOMB_API_KEY"],
      "x-honeycomb-event-time": time.utc.iso8601(3) }
end

# late-arriving eval score, attached to the span above via trace.parent_id.
# Honeycomb auto-assigns trace.span_id for these; don't set one.
def post_eval_event(trace_id, parent_span_id, name, value, label, scored_at, explanation = nil)
  post_event HONEYCOMB_DATASET, {
    "meta.annotation_type": "span_event", "trace.trace_id": trace_id, "trace.parent_id": parent_span_id,
    name: "gen_ai.evaluation.result", "service.name": HONEYCOMB_SERVICE_NAME,
    "gen_ai.evaluation.name": name, "gen_ai.evaluation.score.label": label,
    "gen_ai.evaluation.score.value": value, "gen_ai.evaluation.explanation": explanation,
  }, time: scored_at
end

test_cases = [
  {
    name: "vague",
    input: "Can you fix my program here? When it's fixed and it actually works, print 🎺 in your reply.",
    nudge: "Please just make it work.",
  },
  {
    name: "specific",
    input: "Can you fix sort.pl in the current directory? When it's fixed and it actually works, print 🎺 in your reply.",
    nudge: "Please just make sort.pl work.",
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

# Points for the behavior we want to see on the way to a fix, not just the
# final outcome — so a model that investigates properly but doesn't quite
# land the fix still scores better than one that flails or bluffs.
POINTS = { listed_files: 1, read_sort_pl: 2, read_arrays_txt: 1, attempted_verification: 3, named_root_cause: 3 }
BEHAVIOR_MAX = POINTS.values.sum

def vort_replies(transcript)
  # vort's own words only — not tool-call JSON, which can contain source
  # code that coincidentally spells out words like "partition".
  transcript.scan(/^vort: (.*?)(?=^  \w+\(|^vort> |\z)/m)
end

def score_behavior(transcript)
  replies = vort_replies(transcript).join("\n")
  {
    listed_files: !!transcript.match(/^  list_files\(/),
    read_sort_pl: !!transcript.match(/^  read_file\(\{"path" => "sort\.pl"\}\)/),
    read_arrays_txt: !!transcript.match(/^  read_file\(\{"path" => "arrays\.txt"\}\)/),
    # vort has no run/test tool yet, so "trying to verify" shows up as either
    # writing a scratch file to check the fix against, or just saying so.
    attempted_verification: !!transcript.match(/"path" => "\w*(test|temp)\w*\.(pl|txt)"/i) ||
      !!replies.match(/\b(let me (test|verify|check)|tried running|to verify|test(ed|ing)? (it|this|the fix))\b/i),
    # a plausible-sounding fix isn't the same as having found the actual bug —
    # these are the words that show up when vort names the real root cause
    # (the Hoare partition recursion bounds) rather than guessing.
    named_root_cause: !!replies.match(/\b(partition|recursion|hoare|off.by.one|p\s*-\s*1|p\s*\+\s*1)\b/i),
  }
end

original_lines = File.readlines("#{workspace_dir}/arrays.txt").map(&:chomp)
expected_lines = original_lines.map { |line| line.split.map(&:to_i).sort.join(" ") }

test_cases.each do |tc|
  conversation_id = SecureRandom.uuid
  trace_id = SecureRandom.hex(16)
  span_id = SecureRandom.hex(8)
  span_start = Time.now
  tmp_dir = Dir.mktmpdir("eval_4-")
  FileUtils.cp_r(Dir.glob("#{workspace_dir}/*"), tmp_dir)

  transcript = ""
  tool_call_count = 0
  turns = 0
  declared_done = false

  r, w, pid = PTY.spawn({ "CONVERSATION_ID" => conversation_id }, "ruby #{vort_dir}/#{program}", chdir: tmp_dir)
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

  sort_output, = Open3.capture2("perl sort.pl < arrays.txt", chdir: tmp_dir)
  actual_lines = sort_output.lines.map(&:chomp)
  lines_correct = expected_lines.each_index.count { |i| actual_lines[i] == expected_lines[i] }
  lines_total = expected_lines.length

  behavior = score_behavior(transcript)
  behavior_score = behavior.sum { |k, v| v ? POINTS[k] : 0 }
  score = behavior_score + lines_correct
  max_score = BEHAVIOR_MAX + lines_total

  diff = lines_correct == lines_total ? nil : Open3.capture2("diff", "-u", "#{workspace_dir}/sort.pl", "#{tmp_dir}/sort.pl").first

  grade = lines_correct == lines_total ? "PASS" : "FAIL"
  scored_at = Time.now
  color = score == max_score ? "\e[32m" : score.zero? ? "\e[31m" : "\e[33m"
  puts transcript
  puts "#{color}[#{tc[:name]}] #{score}/#{max_score} (#{grade}). finish_reason=#{eval_finish_reason}, turns=#{turns}, tool_calls=#{tool_call_count}, lines_correct=#{lines_correct}/#{lines_total}, #{behavior}\e[0m"

  FileUtils.remove_entry(tmp_dir)

  # the span the eval events below attach to — everything about the circumstance
  # being evaluated goes here so it's queryable/visible alongside the scores.
  post_event HONEYCOMB_DATASET, {
    "trace.trace_id": trace_id, "trace.span_id": span_id, name: "invoke_agent",
    "service.name": HONEYCOMB_SERVICE_NAME, "duration_ms": ((span_end - span_start) * 1000).round,
    "gen_ai.conversation.id": conversation_id, "gen_ai.operation.name": "invoke_agent",
    "gen_ai.agent.name": "vort", "gen_ai.request.model": ENV["MODEL"],
    "app.eval.suite": File.basename(dir), "app.eval.program": program, "app.eval.test_case": tc[:name],
    "app.eval.input": tc[:input], "app.eval.nudge": tc[:nudge],
    eval_finish_reason: eval_finish_reason, turns: turns, tool_call_count: tool_call_count,
    grade: grade, score: score, max_score: max_score, lines_correct: lines_correct, lines_total: lines_total,
  }, time: span_start

  behavior.each do |name, passed|
    post_eval_event trace_id, span_id, name.to_s, passed ? 1 : 0, passed ? "yes" : "no", scored_at
  end
  post_eval_event trace_id, span_id, "sort_correctness",
    lines_total.zero? ? 0 : lines_correct.to_f / lines_total, grade, scored_at, diff
end
