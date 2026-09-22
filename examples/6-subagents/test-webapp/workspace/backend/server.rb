#!/usr/bin/env ruby
require "webrick"
require "json"

server = WEBrick::HTTPServer.new(Port: 4567)
server.mount_proc("/api/greeting") { |req, res| res.body = { message: "hello from backend" }.to_json }
trap("INT") { server.shutdown }
server.start
