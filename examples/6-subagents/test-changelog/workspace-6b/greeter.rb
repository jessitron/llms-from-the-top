#!/usr/bin/env ruby
name = ARGV[0] || "World"
greetings = ["Hello", "Hi", "Hey", "Greetings", "Welcome"]
greeting = greetings.sample
puts "#{greeting}, #{name}!"
