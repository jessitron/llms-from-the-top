#!/usr/bin/env ruby
require "net/http"
require "json"

dir = "#{__dir__}/workspace"
pid = spawn("ruby #{dir}/backend/server.rb", out: File::NULL, err: File::NULL)

begin
  response = nil
  20.times do
    begin
      response = Net::HTTP.get_response(URI("http://localhost:4567/api/greeting"))
      break
    rescue Errno::ECONNREFUSED
      sleep 0.25
    end
  end

  raise "backend never came up" unless response
  body = JSON.parse(response.body)
  raise "backend returned an empty object: #{body}" if body.empty?
  field = body.keys.first

  frontend = File.read("#{dir}/frontend/index.html")
  raise "frontend doesn't reference '#{field}' field from backend (#{body.inspect})" unless frontend.include?("data.#{field}")

  puts "PASS: backend served #{body.inspect}, frontend reads matching field '#{field}'"
ensure
  Process.kill("INT", pid)
  Process.wait(pid)
end
