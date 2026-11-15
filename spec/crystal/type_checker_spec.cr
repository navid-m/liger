require "../spec_helper"
require "file_utils"

private def with_type_check_project(&)
  workspace = File.tempname("liger-typecheck-spec-")
  Dir.mkdir_p(File.join(workspace, "src"))

  File.write(File.join(workspace, "shard.yml"), <<-YAML)
    name: typecheck_spec
    version: 0.1.0

    targets:
      typecheck_spec:
        main: src/main.cr
    YAML

  File.write(File.join(workspace, "src", "helper.cr"), <<-CRYSTAL)
    module Helper
      def self.add(a : Int32, b : Int32) : Int32
        a + b
      end
    end
    CRYSTAL

  begin
    yield workspace
  ensure
    FileUtils.rm_rf(workspace)
  end
end

describe Liger::SemanticAnalyzer do
  it "reports a type mismatch across project files" do
    with_type_check_project do |workspace|
      source = <<-CRYSTAL
        require "./helper"

        Helper.add("not a number", 2)
        CRYSTAL

      main_file = File.join(workspace, "src", "main.cr")
      File.write(main_file, source)
      uri = "file://#{main_file}"

      analyzer = Liger::SemanticAnalyzer.new("file://#{workspace}")
      analyzer.update_source(uri, source)
      diagnostics = analyzer.analyze(uri)

      diagnostics.should_not be_empty
      diagnostics.any?(&.message.includes?("Int32")).should be_true
    end
  end

  it "uses the unsaved buffer of a file required by the project" do
    with_type_check_project do |workspace|
      File.write(File.join(workspace, "src", "main.cr"), <<-CRYSTAL)
        require "./helper"

        Helper.add(1, 2)
        CRYSTAL

      source = <<-CRYSTAL
        module Helper
          def self.add(a : Int32, b : Int32) : Int32
            a + "not a number"
          end
        end
        CRYSTAL

      helper_file = File.join(workspace, "src", "helper.cr")
      uri = "file://#{helper_file}"

      analyzer = Liger::SemanticAnalyzer.new("file://#{workspace}")
      analyzer.update_source(uri, source)
      diagnostics = analyzer.analyze(uri)

      diagnostics.should_not be_empty
      diagnostics.any?(&.message.includes?("String")).should be_true
    end
  end

  it "checks a file that is not required by the project main" do
    with_type_check_project do |workspace|
      File.write(File.join(workspace, "src", "main.cr"), "puts Helper.add(1, 2)\n")
      Dir.mkdir_p(File.join(workspace, "examples"))

      source = <<-CRYSTAL
        def greet(name : String)
          name
        end

        greet(123)
        CRYSTAL

      example_file = File.join(workspace, "examples", "sample.cr")
      File.write(example_file, source)
      uri = "file://#{example_file}"

      analyzer = Liger::SemanticAnalyzer.new("file://#{workspace}")
      analyzer.update_source(uri, source)
      diagnostics = analyzer.analyze(uri)

      diagnostics.should_not be_empty
      diagnostics.any?(&.message.includes?("Int32")).should be_true
    end
  end

  it "reports a type mismatch in a standalone file" do
    source = <<-CRYSTAL
      def add(a : Int32, b : Int32) : Int32
        a + b
      end

      add("not a number", 2)
      CRYSTAL

    file = File.tempname("liger-typecheck-spec-", ".cr")
    File.write(file, source)
    uri = "file://#{file}"

    analyzer = Liger::SemanticAnalyzer.new
    analyzer.update_source(uri, source)
    diagnostics = analyzer.analyze(uri)

    diagnostics.should_not be_empty
    diagnostics.any?(&.message.includes?("Int32")).should be_true
  ensure
    File.delete(file) if file && File.exists?(file)
  end

  it "reports literal mismatches after an earlier compiler error" do
    source = <<-CRYSTAL
      def broken : String
        1
      end

      broken

      def some_thing(number : Int32)
        puts number
      end

      some_thing("hello")
      CRYSTAL

    file = File.tempname("liger-typecheck-spec-", ".cr")
    File.write(file, source)
    uri = "file://#{file}"

    analyzer = Liger::SemanticAnalyzer.new
    analyzer.update_source(uri, source)
    diagnostics = analyzer.analyze(uri)

    diagnostics.any?(&.message.includes?("some_thing")).should be_true
  ensure
    File.delete(file) if file && File.exists?(file)
  end

  it "only reports syntax errors in lax mode" do
    source = <<-CRYSTAL
      def add(a : Int32, b : Int32) : Int32
        a + b
      end

      add("not a number", 2)
      CRYSTAL

    file = File.tempname("liger-typecheck-spec-", ".cr")
    File.write(file, source)
    uri = "file://#{file}"

    analyzer = Liger::SemanticAnalyzer.new
    analyzer.lax = true
    analyzer.update_source(uri, source)

    analyzer.analyze(uri).should be_empty
  ensure
    File.delete(file) if file && File.exists?(file)
  end
end
