# Sample Crystal file for testing Liger LSP features

module SampleModule
  # A sample class demonstrating various Crystal features
  class SampleClass
    # Instance variable
    @name : String
    @count : Int32

    # Class variable
    @@total_instances = 0

    # Constructor
    def initialize(@name : String, @count : Int32 = 0)
      @@total_instances += 1
    end

    # Instance method with return type
    def greet : String
      "Hello, #{@name}!"
    end

    # Method with parameters
    def increment(amount : Int32 = 1) : Int32
      @count += amount
      @count
    end

    # Predicate method
    def empty? : Bool
      @count == 0
    end

    # Method with block
    def each_count(&block : Int32 -> Nil)
      @count.times do |i|
        block.call(i)
      end
    end

    # Class method
    def self.total_instances : Int32
      @@total_instances
    end

    # Property macros
    property name : String
    getter count : Int32
  end

  # A struct example
  struct Point
    property x : Float64
    property y : Float64

    def initialize(@x : Float64, @y : Float64)
    end

    def distance_from_origin : Float64
      Math.sqrt(@x ** 2 + @y ** 2)
    end
  end

  # An enum example
  enum Color
    Red
    Green
    Blue

    def to_hex : String
      case self
      when Red   then "#FF0000"
      when Green then "#00FF00"
      when Blue  then "#0000FF"
      end
    end
  end

  # A module with methods
  module Utilities
    extend self

    def format_number(num : Int32) : String
      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
    end

    def random_string(length : Int32 = 10) : String
      Random::Secure.random_bytes(length).hexstring[0...length]
    end
  end
end

# Usage examples
sample = SampleModule::SampleClass.new("Test", 5)
puts sample.greet
puts sample.increment(3)
puts sample.empty?

point = SampleModule::Point.new(3.0, 4.0)
puts point.distance_from_origin

color = SampleModule::Color::Red
puts color.to_hex

puts SampleModule::Utilities.format_number(1234567)
puts SampleModule::Utilities.random_string(16)
