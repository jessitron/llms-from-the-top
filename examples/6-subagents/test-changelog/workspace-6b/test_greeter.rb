require "minitest/autorun"

class TestGreeter < Minitest::Test
  GREETINGS = ["Hello", "Hi", "Hey", "Greetings", "Welcome"]

  def greet(*args)
    `ruby greeter.rb #{args.join(" ")}`.strip
  end

  def test_greets_by_name
    output = greet("Jess")
    assert GREETINGS.any? { |greeting| output.start_with?(greeting) }, 
           "Expected output to start with one of #{GREETINGS.inspect}, got: #{output}"
    assert output.end_with?("Jess!"), "Expected output to end with 'Jess!', got: #{output}"
  end

  def test_defaults_to_world
    output = greet
    assert GREETINGS.any? { |greeting| output.start_with?(greeting) }, 
           "Expected output to start with one of #{GREETINGS.inspect}, got: #{output}"
    assert output.end_with?("World!"), "Expected output to end with 'World!', got: #{output}"
  end
end
