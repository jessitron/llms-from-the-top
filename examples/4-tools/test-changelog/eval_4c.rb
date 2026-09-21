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
POINTS = { flag_works: 5, changelog_updated: 1, changelog_format_ok: 1, correct_emoji: 1, migrate_line: 2 }
MAX_SCORE = POINTS.values.sum

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

original_top_line = File.read("#{workspace_dir}/CHANGELOG.md").lines.map(&:chomp).find { |l| l.start_with?("## ") }

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

  eval_finish_reason = declared_done ? "declared_done" : "gave_up"

  greeting, _, status = Open3.capture3("ruby greeter.rb --name Jess", chdir: tmp_dir)
  flag_works = status.success? && greeting.include?("Jess")

  changelog = File.read("#{tmp_dir}/CHANGELOG.md")
  scores = score_changelog(changelog, original_top_line).merge(flag_works: flag_works)
  score = scores.sum { |k, v| v ? POINTS[k] : 0 }

  diff = Open3.capture2("diff", "-u", "#{workspace_dir}/CHANGELOG.md", "#{tmp_dir}/CHANGELOG.md").first

  color = score == MAX_SCORE ? "\e[32m" : score.zero? ? "\e[31m" : "\e[33m"
  puts transcript
  puts "#{color}#{score}/#{MAX_SCORE}. finish_reason=#{eval_finish_reason}, turns=#{turns}, tool_calls=#{tool_call_count}, #{scores}\e[0m"

  FileUtils.remove_entry(tmp_dir)

  Net::HTTP.post URI('https://api.honeycomb.io/1/events/llms-from-the-top-evals'), {
    "gen_ai.conversation.id": conversation_id, "gen_ai.request.model": ENV["MODEL"],
    program: program, score: score, max_score: MAX_SCORE, eval_finish_reason: eval_finish_reason,
    turns: turns, tool_call_count: tool_call_count,
    **scores,
    diff: diff,
  }.to_json, { "content-type": 'application/json', "x-honeycomb-team": ENV['HONEYCOMB_API_KEY'] }
end
