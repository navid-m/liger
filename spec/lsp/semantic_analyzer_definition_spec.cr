require "../spec_helper"
require "../../src/crystal/semantic_analyzer"

describe Liger::SemanticAnalyzer do
  it "finds definition of instance variable" do
    analyzer = Liger::SemanticAnalyzer.new
    uri = "file:///test.cr"
    source = "class A\n  @x : Int32\n  def foo\n    @x\n  end\nend"
    analyzer.update_source(uri, source)
    location = analyzer.find_definition(uri, LSP::Position.new(3, 5))
    if location.nil?
      fail "Location should not be nil for cursor on 'x'"
    end

    location.should_not be_nil
    loc = location.as(LSP::Location)
    loc.uri.should eq(uri)
    loc.range.start.line.should eq(1)
  end

  it "finds definition of class variable" do
    analyzer = Liger::SemanticAnalyzer.new
    uri = "file:///test_cv.cr"
    source = "class A\n  @@y : Int32\n  def foo\n    @@y\n  end\nend"
    analyzer.update_source(uri, source)
    location = analyzer.find_definition(uri, LSP::Position.new(3, 6))

    if location.nil?
      fail "Location should not be nil for cursor on 'y' of class variable"
    end

    location.should_not be_nil
    loc = location.as(LSP::Location)

    loc.uri.should eq(uri)
    loc.range.start.line.should eq(1)
  end
end
