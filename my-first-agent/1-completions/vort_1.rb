#!/usr/bin/env ruby
# implementation goes here

require 'net/http'
require 'json'

print 'vort> '
input = gets.chomp

request = { model: 'base', prompt: input }
api_url = ENV.fetch('LLM_API_URL', 'https://llms-from-the-top.jessitron.com')
uri = URI("#{api_url}/v1/completions")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = uri.scheme == 'https'
# Modal cold starts (model load + GPU warmup) can take longer than the 60s default.
http.open_timeout = 120
http.read_timeout = 120
response = http.post uri, request.to_json, {
  "x-api-key": 'hydro-building',
  "use-this-model-please": 'base',
  "content-type": 'application/json'
}
case response
in Net::HTTPSuccess
  completion = JSON.parse(response.body)
  assistant_message = completion.dig('choices', 0, 'text')
  puts assistant_message
else
  puts "Error: #{response.code} #{response.message}", response.body
end
