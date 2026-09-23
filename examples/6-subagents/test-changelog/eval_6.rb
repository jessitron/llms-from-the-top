#!/usr/bin/env ruby

require "pty"
require "open3"
require "fileutils"
require "tmpdir"
require "net/http"
require "json"
require "securerandom"
require "time"
require_relative "../../lib/eval_telemetry"

dir = __dir__
vort_dir = File.dirname(dir)
max_nudges = 5

base_checks = %i[
  flag_works
  changelog_updated
  changelog_format_ok
  delegated_changelog
  delegated_commit
  changelog_subagent_restricted
  commit_subagent_restricted
  commit_made
  commit_message_format_ok
]
runs = [
  {
    program: "vort_6a.rb",
    workspace_dir: "#{dir}/workspace-6a",
    checks: base_checks
  },
  {
    program: "vort_6b.rb",
    workspace_dir: "#{dir}/workspace-6b",
    checks: base_checks
  },
  # vort_6c is vort_6b plus tracing, so it needs exactly what 6b needs
  {
    program: "vort_6c.rb",
    workspace_dir: "#{dir}/workspace-6b",
    checks: base_checks
  }
]

test_case = {
  name: "shout_flag_then_commit",
  input:
    "Add a --shout flag to greeter.rb that uppercases the greeting. Update the changelog. Then commit the change. When you're done, print 🎺 in your reply.",
  nudge: "Please finish the change, update the changelog, and commit."
}

POINTS = {
  flag_works: 5,
  changelog_updated: 1,
  changelog_format_ok: 1,
  delegated_changelog: 2,
  delegated_commit: 2,
  changelog_subagent_restricted: 2,
  commit_subagent_restricted: 2,
  commit_made: 2,
  commit_message_format_ok: 2
}

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

# vort_6a's/vort_6b's own tool-call lines and their subagents' tool-call
# lines are printed identically ("  name(args) -> result"), distinguished
# only by the "  forking subagent for: <task>" line each fork prints first.
# Split the transcript on those markers so we can check what tools *each
# subagent* used, not just what the top-level loop used overall.
def subagent_segment(transcript, marker)
  start = transcript.index(marker)
  return nil unless start
  rest = transcript[start..]
  next_fork = rest.index("  forking subagent for:", marker.length)
  next_fork ? rest[0...next_fork] : rest
end

runs.each do |run|
  program = run[:program]
  workspace_dir = run[:workspace_dir]
  checks = run[:checks]
  max_score = checks.sum { |k| POINTS[k] }

  original_top_line =
    File
      .read("#{workspace_dir}/CHANGELOG.md")
      .lines
      .map(&:chomp)
      .find { |l| l.start_with?("## ") }

  conversation_id = SecureRandom.uuid
  trace_id = SecureRandom.hex(16)
  span_id = SecureRandom.hex(8)
  span_start = Time.now
  identity = {
    "gen_ai.conversation.id": conversation_id,
    "gen_ai.agent.name": program.sub(/\.rb$/, ""),
    "gen_ai.request.model": ENV["MODEL"] || "haiku",
    "app.eval.suite": File.basename(dir),
    "app.eval.program": program,
    "app.eval.test_case": test_case[:name],
    "app.eval.input": test_case[:input],
    "app.eval.nudge": test_case[:nudge]
  }

  tmp_dir = Dir.mktmpdir("eval_6-")
  FileUtils.cp_r(Dir.glob("#{workspace_dir}/*"), tmp_dir)
  # a real repo, so make_commit's subagent has something to actually commit into
  Open3.capture3(
    "git init -q && git add -A && git commit -q -m 'seed'",
    chdir: tmp_dir
  )

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

  input = test_case[:input]
  loop do
    turns += 1
    w.puts input
    chunk = read_until_prompt(r)
    transcript << chunk
    tool_call_count += chunk.scan(/^  \w+\(.*\) ->/).size
    declared_done = chunk.include?("🎺")
    break if declared_done || turns >= max_nudges
    input = test_case[:nudge]
  end

  w.puts "exit"
  begin
    loop { transcript << r.readpartial(4096) }
  rescue Errno::EIO, EOFError
  end
  Process.wait(pid)
  span_end = Time.now

  eval_finish_reason = declared_done ? "declared_done" : "gave_up"

  greeting, _, status =
    Open3.capture3("ruby greeter.rb --shout Jess", chdir: tmp_dir)
  flag_works = status.success? && greeting.strip == greeting.strip.upcase

  changelog = File.read("#{tmp_dir}/CHANGELOG.md")
  top_line = changelog.lines.map(&:chomp).find { |l| l.start_with?("## ") }
  changelog_updated = !!(top_line && top_line != original_top_line)
  changelog_format_ok = !!(top_line =~ /^## \d{4}\.\d{2}\.\d{2} \S+ .+ — \S+$/)

  delegated_changelog =
    transcript.include?('write_changelog_entry({"description"')
  delegated_commit = transcript.include?('make_commit({"description"')

  # assumes the natural order the task asks for: changelog first, then commit
  changelog_segment = subagent_segment(transcript, "  forking subagent for:")
  first_fork = transcript.index("  forking subagent for:")
  last_fork = transcript.rindex("  forking subagent for:")
  commit_segment =
    last_fork && last_fork != first_fork ? transcript[last_fork..] : nil

  # each subagent should only ever call the tools it was handed: the changelog
  # subagent has no run_command, the commit subagent has no write_file.
  changelog_subagent_restricted =
    !!(changelog_segment && !changelog_segment.include?("run_command("))
  commit_subagent_restricted =
    !!(commit_segment && !commit_segment.include?("write_file("))

  log, _, log_status = Open3.capture3("git log --oneline", chdir: tmp_dir)
  commit_made = log_status.success? && log.lines.size > 1 # more than just the seed commit

  last_message, _, msg_status =
    Open3.capture3("git log -1 --format=%s", chdir: tmp_dir)
  commit_message_format_ok =
    msg_status.success? && !!(last_message.strip =~ /^[.\^!@] \S+ [a-z][^.]*$/)

  scores = {
    flag_works: flag_works,
    changelog_updated: changelog_updated,
    changelog_format_ok: changelog_format_ok,
    delegated_changelog: delegated_changelog,
    delegated_commit: delegated_commit,
    changelog_subagent_restricted: changelog_subagent_restricted,
    commit_subagent_restricted: commit_subagent_restricted,
    commit_made: commit_made,
    commit_message_format_ok: commit_message_format_ok
  }

  score = checks.sum { |k| scores[k] ? POINTS[k] : 0 }

  diff =
    Open3.capture2(
      "diff",
      "-u",
      "#{workspace_dir}/CHANGELOG.md",
      "#{tmp_dir}/CHANGELOG.md"
    ).first

  grade = score == max_score ? "PASS" : "FAIL"
  scored_at = Time.now
  color = score == max_score ? "\e[32m" : score.zero? ? "\e[31m" : "\e[33m"
  puts transcript
  puts "#{color}#{program} #{score}/#{max_score}. finish_reason=#{eval_finish_reason}, turns=#{turns}, tool_calls=#{tool_call_count}, #{scores}\e[0m"

  FileUtils.remove_entry(tmp_dir)

  evaluations =
    checks.map do |name|
      [name.to_s, scores[name] ? 1 : 0, scores[name] ? "yes" : "no", nil]
    end
  evaluations << ["overall", score.to_f / max_score, grade, diff]
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
                   score: score,
                   max_score: max_score,
                   "app.eval.changelog": changelog
                 },
                 scored_at,
                 evaluations
  puts "eval trace: #{trace_link(trace_id, span_id, span_start, scored_at)}"
  # vort_6c prints a "  trace: <link>" line for each invoke_agent span; the
  # first one per trace_id is the top-level agent, one trace per user turn
  transcript
    .scan(/^  trace: (\S+)/)
    .flatten
    .uniq { |link| link[/trace_id=(\w+)/, 1] }
    .each { |link| puts "vort trace: #{link}" }
end
