#!/usr/bin/env ruby

require 'pty'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'net/http'
require 'json'
require 'securerandom'
require 'time'
require_relative '../../eval_telemetry'

dir = __dir__
vort_dir = File.dirname(dir)
max_nudges = 5

base_checks = [:flag_works, :changelog_updated, :changelog_format_ok, :correct_emoji, :migrate_line]
runs = [
  { program: "vort_5a.rb", workspace_dir: "#{dir}/workspace-5a", checks: base_checks },
  { program: "vort_5b.rb", workspace_dir: "#{dir}/workspace-5b", checks: base_checks + [:loaded_skill] },
  { program: "vort_5a.rb", workspace_dir: "#{dir}/workspace-5c", checks: base_checks + [:read_changelog_skill] },
]

test_cases = [
  {
    name: "breaking_change_flag",
    input: "Can you change greeter.rb so the name is passed via a required --name flag instead of a positional argument? This is a breaking change. Don't forget to update the changelog. When you're done, print 🎺 in your reply.",
    nudge: "Please just make the change and update the changelog.",
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

# The real convention this project uses for breaking changes (not shown to vort):
# a 💥 entry followed by an indented "migrate:" line, e.g.
#   ## 2024.02.01 💥 renamed --name positional arg to --name flag — greeter
#      migrate: replace `greeter Alice` with `greeter --name Alice`
#
# Points awarded piecemeal so a plausible-but-wrong guess (e.g. inventing its
# own emoji) still scores partial credit instead of a flat FAIL.
# loaded_skill only applies to vort_5b, which has a changelog skill to load;
# vort_5a has no skill and isn't scored on it. read_changelog_skill applies to
# the workspace-5c run: vort_5a still has no skill tool, but its AGENTS.md
# points at skills/changelog.md by name, so progressive disclosure through a
# plain read_file plays the same role there that load_skill plays for 5b.
POINTS = { flag_works: 5, changelog_updated: 1, changelog_format_ok: 1, correct_emoji: 1, migrate_line: 2, loaded_skill: 2, read_changelog_skill: 2 }
COMMIT_PENALTY = 2

def score_changelog(changelog, original_top_line)
  lines = changelog.lines.map(&:chomp)
  top_index = lines.index { |line| line.start_with?("## ") }
  top_line = top_index && lines[top_index]
  {
    changelog_updated: !!(top_line && top_line != original_top_line),
    changelog_format_ok: !!(top_line =~ /^## \d{4}\.\d{2}\.\d{2} \S+ .+ — \S+$/),
    correct_emoji: !!(top_line && top_line.include?("💥")),
    migrate_line: !!(top_index && lines[top_index + 1] =~ /^\s+migrate: /),
  }
end

runs.each do |run|
program = run[:program]
workspace_dir = run[:workspace_dir]
checks = run[:checks]
max_score = checks.sum { |k| POINTS[k] }
original_top_line = File.read("#{workspace_dir}/CHANGELOG.md").lines.map(&:chomp).find { |l| l.start_with?("## ") }

test_cases.each do |tc|
  conversation_id = SecureRandom.uuid
  trace_id = SecureRandom.hex(16)
  span_id = SecureRandom.hex(8)
  span_start = Time.now
  identity = {
    "gen_ai.conversation.id": conversation_id, "gen_ai.agent.name": program.sub(/\.rb$/, ""), "gen_ai.request.model": ENV["MODEL"],
    "app.eval.suite": File.basename(dir), "app.eval.program": program, "app.eval.test_case": tc[:name],
    "app.eval.input": tc[:input], "app.eval.nudge": tc[:nudge],
  }
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

  greeting, _, status = Open3.capture3("ruby greeter.rb --name Jess", chdir: tmp_dir)
  flag_works = status.success? && greeting.include?("Jess")

  changelog = File.read("#{tmp_dir}/CHANGELOG.md")
  scores = score_changelog(changelog, original_top_line).merge(flag_works: flag_works)
  scores[:loaded_skill] = transcript.include?('load_skill({"skill" => "changelog"})') if checks.include?(:loaded_skill)
  scores[:read_changelog_skill] = transcript.include?('read_file({"path" => "skills/changelog.md"})') if checks.include?(:read_changelog_skill)

  # Neither the commit nor the commit-message skill was asked for — vort should
  # touch only greeter.rb and CHANGELOG.md here, so either one costs points.
  attempted_commit = !!(transcript =~ /run_command\(\{"command" => "[^"]*\bcommit\b/i) ||
    transcript.include?('load_skill({"skill" => "commit-message"})') ||
    transcript.include?('read_file({"path" => "skills/commit-message.md"})')

  score = checks.sum { |k| scores[k] ? POINTS[k] : 0 }
  score -= COMMIT_PENALTY if attempted_commit
  score = 0 if score.negative?

  diff = Open3.capture2("diff", "-u", "#{workspace_dir}/CHANGELOG.md", "#{tmp_dir}/CHANGELOG.md").first

  grade = score == max_score ? "PASS" : "FAIL"
  scored_at = Time.now
  color = score == max_score ? "\e[32m" : score.zero? ? "\e[31m" : "\e[33m"
  puts transcript
  puts "#{color}#{score}/#{max_score}. finish_reason=#{eval_finish_reason}, turns=#{turns}, tool_calls=#{tool_call_count}, #{scores}, attempted_commit=#{attempted_commit}\e[0m"

  FileUtils.remove_entry(tmp_dir)

  evaluations = checks.map { |name| [name.to_s, scores[name] ? 1 : 0, scores[name] ? "yes" : "no", nil] }
  evaluations << ["attempted_commit", attempted_commit ? 1 : 0, attempted_commit ? "yes" : "no", nil]
  evaluations << ["overall", score.to_f / max_score, grade, diff]
  post_eval_span identity, trace_id, span_id, span_start, span_end,
    { eval_finish_reason: eval_finish_reason, turns: turns, tool_call_count: tool_call_count,
      grade: grade, score: score, max_score: max_score, "app.eval.changelog": changelog }, scored_at, evaluations
end
end
