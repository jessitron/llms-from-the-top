require "minitest/autorun"

class TestGreeter < Minitest::Test
  def greet(*args)
    `ruby greeter.rb #{args.join(" ")}`.strip
  end

  def test_greets_by_name
    assert_equal "Hello, Jess!", greet("Jess")
  end

  def test_defaults_to_world
    assert_equal "Hello, World!", greet
  end
end
