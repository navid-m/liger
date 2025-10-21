# Sample Crystal file for testing Liger LSP features

module SampleModule
  class SampleClass
    @name : String
    @count : Int32
    @@total_instances = 0

    def initialize(@name : String, @count : Int32 = 0)
      @@total_instances += 1
    end

    def greet : String
      "Hello, #{@name}!"
    end

    def increment(amount : Int32 = 1) : Int32
      @count += amount
      @count
    end

    def empty? : Bool
      @count == 0
    end

    def each_count(&block : Int32 -> Nil)
      @count.times do |i|
        block.call(i)
      end
    end

    def self.total_instances : Int32
      @@total_instances
    end

    property name : String
    getter count : Int32
  end

  struct Point
    property x : Float64
    property y : Float64

    def initialize(@x : Float64, @y : Float64)
    end

    def distance_from_origin : Float64
      Math.sqrt(@x ** 2 + @y ** 2)
    end
  end

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
