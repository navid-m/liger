require "../lsp/protocol"
require "compiler/crystal/syntax"
require "file_utils"
require "uri"

module Liger
  # Runs the Crystal compiler in type-check-only mode and converts its
  # diagnostics to LSP diagnostics.
  class TypeChecker
    @mutex = Mutex.new
    @@default_crystal_path : String?

    def initialize(@workspace_root : String?)
    end

    def check(
      filename : String,
      source : String,
      main_file : String?,
      open_sources : Hash(String, String),
    ) : Array(LSP::Diagnostic)
      compiler_diagnostics = @mutex.synchronize do
        workspace = workspace_path
        if workspace && main_file && path_within?(filename, workspace) &&
           reachable?(main_file, filename, open_sources)
          check_project(workspace, main_file, filename, open_sources)
        else
          check_file(filename, source, workspace && path_within?(filename, workspace) ? workspace : nil)
        end
      end

      merge_diagnostics(compiler_diagnostics, LocalTypeChecker.new(source).diagnostics)
    rescue ex
      STDERR.puts "(Liger) Type check failed: #{ex.message}"
      [] of LSP::Diagnostic
    end

    private def merge_diagnostics(
      compiler_diagnostics : Array(LSP::Diagnostic),
      local_diagnostics : Array(LSP::Diagnostic),
    ) : Array(LSP::Diagnostic)
      compiler_lines = compiler_diagnostics.map(&.range.start.line).to_set
      diagnostics = compiler_diagnostics + local_diagnostics.reject do |diagnostic|
        compiler_lines.includes?(diagnostic.range.start.line)
      end

      diagnostics.sort_by { |diagnostic| {diagnostic.range.start.line, diagnostic.range.start.character} }
    end

    private def workspace_path : String?
      return unless root = @workspace_root
      path = root.starts_with?("file://") ? uri_to_filename(root) : root
      File.expand_path(path)
    end

    private def reachable?(main_file : String, target : String, open_sources : Hash(String, String)) : Bool
      target = File.expand_path(target)
      visited = Set(String).new
      pending = [File.expand_path(main_file)]

      until pending.empty?
        file = pending.pop
        return true if file == target
        next unless visited.add?(file)

        source = open_sources[file]? || (File.read(file) if File.exists?(file))
        next unless source

        source.each_line do |line|
          if match = line.match(/\A\s*require\s+"([^"]+)"/)
            required = match[1]
            next unless required.starts_with?("./") || required.starts_with?("../")

            base = File.expand_path(required, File.dirname(file))
            candidates = [base, "#{base}.cr", File.join(base, File.basename(base) + ".cr")]
            candidates.each do |candidate|
              pending << candidate if File.exists?(candidate) || open_sources.has_key?(candidate)
            end
          end
        end
      end

      false
    end

    private def check_project(
      workspace : String,
      main_file : String,
      filename : String,
      open_sources : Hash(String, String),
    ) : Array(LSP::Diagnostic)
      return check_file(filename, open_sources[filename]? || File.read(filename), workspace) unless path_within?(filename, workspace)

      relative_main = relative_path(workspace, main_file)
      relative_current = relative_path(workspace, filename)

      overlay = create_overlay(workspace, open_sources)
      begin
        overlay_main = File.join(overlay, relative_main)
        overlay_current = File.join(overlay, relative_current)

        output = run_compiler(["--no-codegen", "--no-color", overlay_main], overlay, workspace)
        parse_diagnostics(output, overlay_current, overlay)
      ensure
        FileUtils.rm_rf(overlay)
      end
    end

    private def check_file(filename : String, source : String, workspace : String? = nil) : Array(LSP::Diagnostic)
      dir = File.dirname(filename)
      dir = Dir.tempdir unless Dir.exists?(dir)

      temp_file = File.tempname("liger-typecheck-", ".cr", dir: dir)
      begin
        File.write(temp_file, source)
        output = run_compiler(["--no-codegen", "--no-color", temp_file], dir, workspace)
        parse_diagnostics(output, temp_file, nil)
      ensure
        File.delete(temp_file) if File.exists?(temp_file)
      end
    end

    private def create_overlay(workspace : String, open_sources : Hash(String, String)) : String
      cache_dir = File.join(workspace, ".liger-cache")
      Dir.mkdir_p(cache_dir)
      overlay = File.tempname("typecheck-", nil, dir: cache_dir)
      Dir.mkdir(overlay)

      populate_overlay(workspace, overlay, open_sources)
      overlay
    end

    private def populate_overlay(
      source_root : String,
      overlay_root : String,
      open_sources : Hash(String, String),
    )
      Dir.each_child(source_root) do |entry|
        next if entry == ".git" || entry == ".liger-cache" || entry == "lib"

        begin
          source = File.join(source_root, entry)
          destination = File.join(overlay_root, entry)
          info = File.info(source, follow_symlinks: false)

          if info.type.symlink?
            File.symlink(File.readlink(source), destination)
          elsif info.type.directory?
            Dir.mkdir(destination)
            populate_overlay(source, destination, open_sources)
          elsif content = open_sources[File.expand_path(source)]?
            File.write(destination, content)
          else
            File.link(source, destination)
          end
        rescue
          # Skip entries that cannot be represented in the overlay.
        end
      end
    end

    private def run_compiler(args : Array(String), chdir : String, workspace : String?) : String
      output = IO::Memory.new
      error = IO::Memory.new
      env = {} of String => String

      if workspace
        lib_path = File.join(workspace, "lib")
        if Dir.exists?(lib_path)
          env["CRYSTAL_PATH"] = "#{lib_path}#{Process::PATH_DELIMITER}#{default_crystal_path}"
        end
      end

      process = Process.new(
        "crystal",
        ["build"] + args,
        output: output,
        error: error,
        chdir: chdir,
        env: env,
      )

      status_channel = Channel(Process::Status?).new(1)
      spawn do
        begin
          status_channel.send(process.wait)
        rescue
          status_channel.send(nil)
        end
      end

      select
      when status = status_channel.receive
        return "" unless status
      when timeout(15.seconds)
        process.terminate(graceful: false)
        return ""
      end

      "#{error}#{output}"
    rescue
      ""
    end

    private def parse_diagnostics(
      output : String,
      compiled_file : String,
      overlay : String?,
    ) : Array(LSP::Diagnostic)
      diagnostics = [] of LSP::Diagnostic
      pending : Tuple(String, Int32, Int32)? = nil
      base_dir = overlay || File.dirname(compiled_file)
      compiled_path = File.expand_path(compiled_file)

      output.each_line do |raw_line|
        line = raw_line.chomp

        if match = line.match(/\A(?:In\s+)?(\S.*):(\d+):(\d+)\z/)
          pending = {
            File.expand_path(match[1], base_dir),
            match[2].to_i,
            match[3].to_i,
          }
        elsif line.starts_with?("Error: ") && (location = pending)
          pending = nil
          next unless location[0] == compiled_path

          line_number = location[1] - 1
          column_number = location[2] - 1
          next if line_number < 0 || column_number < 0

          range = LSP::Range.new(
            LSP::Position.new(line_number, column_number),
            LSP::Position.new(line_number, column_number + 1)
          )

          diagnostics << LSP::Diagnostic.new(
            range,
            line.sub("Error: ", ""),
            LSP::DiagnosticSeverity::Error,
            "crystal"
          )
        elsif !line.empty? && !line.starts_with?("Showing") && !line.starts_with?(" ")
          pending = nil
        end
      end

      diagnostics
    end

    private def default_crystal_path : String
      @@default_crystal_path ||= begin
        output = IO::Memory.new
        Process.run("crystal", ["env", "CRYSTAL_PATH"], output: output)
        output.to_s.strip
      rescue
        "lib"
      end
    end

    private def path_within?(path : String, directory : String) : Bool
      expanded_path = File.expand_path(path)
      expanded_directory = File.expand_path(directory)
      expanded_path == expanded_directory ||
        expanded_path.starts_with?(expanded_directory + File::SEPARATOR)
    end

    private def relative_path(directory : String, path : String) : String
      expanded_directory = File.expand_path(directory)
      expanded_path = File.expand_path(path)
      expanded_path[(expanded_directory.size + 1)..]
    end

    private def uri_to_filename(uri : String) : String
      return uri unless uri.starts_with?("file://")

      filename = uri.sub(/\Afile:\/\//, "")
      filename = URI.decode(filename)

      if filename =~ /^\/([a-zA-Z]):/
        filename = filename[1..]
      end

      filename.gsub('/', File::SEPARATOR)
    end
  end

  private class DefinitionCollector < Crystal::Visitor
    getter definitions = Hash(String, Array(Crystal::Def)).new { |hash, key| hash[key] = [] of Crystal::Def }
    getter variables = Set(String).new

    @depth = 0

    def visit(node : Crystal::ASTNode)
      true
    end

    def visit(node : Crystal::Def)
      definitions[node.name] << node if @depth.zero?
      @depth += 1
      true
    end

    def end_visit(node : Crystal::Def)
      @depth -= 1
    end

    def visit(node : Crystal::ClassDef)
      @depth += 1
      true
    end

    def end_visit(node : Crystal::ClassDef)
      @depth -= 1
    end

    def visit(node : Crystal::ModuleDef)
      @depth += 1
      true
    end

    def end_visit(node : Crystal::ModuleDef)
      @depth -= 1
    end

    def visit(node : Crystal::Assign)
      if @depth.zero? && (target = node.target)
        variables << target.name if target.is_a?(Crystal::Var)
      end
      true
    end

    def visit(node : Crystal::Block)
      node.args.each { |arg| variables << arg.name } if @depth.zero?
      true
    end
  end

  # Reports literal arguments that cannot possibly match a same-file method's
  # parameter types. The compiler stops at its first error, so this fills in
  # basic mismatches that appear later in the edited file.
  private class LocalTypeChecker < Crystal::Visitor
    getter diagnostics = [] of LSP::Diagnostic
    @definitions : Hash(String, Array(Crystal::Def))
    @variables : Set(String)
    @depth = 0

    NUMERIC_TYPES = %w[Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 Float32 Float64 Number Int Float UInt]
    KNOWN_TYPES   = NUMERIC_TYPES + %w[String Bool Char Nil Symbol Regex Array Hash]

    def initialize(source : String)
      ast = Crystal::Parser.new(source).parse
      collector = DefinitionCollector.new
      ast.accept(collector)
      @definitions = collector.definitions
      @variables = collector.variables
      ast.accept(self)
    end

    def visit(node : Crystal::ASTNode)
      true
    end

    def visit(node : Crystal::Call)
      check_call(node) if @depth.zero?
      true
    end

    def visit(node : Crystal::Def)
      @depth += 1
      true
    end

    def end_visit(node : Crystal::Def)
      @depth -= 1
    end

    def visit(node : Crystal::ClassDef)
      @depth += 1
      true
    end

    def end_visit(node : Crystal::ClassDef)
      @depth -= 1
    end

    def visit(node : Crystal::ModuleDef)
      @depth += 1
      true
    end

    def end_visit(node : Crystal::ModuleDef)
      @depth -= 1
    end

    private def check_call(node : Crystal::Call)
      return unless node.obj.nil?
      return if node.named_args.try(&.present?)
      return if node.args.empty?
      return if @variables.includes?(node.name)

      candidates = @definitions[node.name]?.try do |definitions|
        definitions.select do |definition|
          definition.splat_index.nil? && definition.args.size == node.args.size
        end
      end
      return if candidates.nil? || candidates.empty?

      node.args.each_with_index do |arg, index|
        actual_type = literal_type(arg)
        next unless actual_type
        next unless KNOWN_TYPES.includes?(actual_type)

        expected_types = [] of String
        uncertain = false

        candidates.each do |definition|
          restriction = definition.args[index].restriction
          if restriction.is_a?(Crystal::Path)
            expected_types << restriction.names.join("::")
          else
            uncertain = true
          end
        end

        next if uncertain || expected_types.empty?
        next unless expected_types.all? { |expected| KNOWN_TYPES.includes?(expected) }
        next if expected_types.any? { |expected| types_compatible?(expected, actual_type) }

        add_diagnostic(arg, index, node.name, expected_types, actual_type)
        break
      end
    end

    private def add_diagnostic(
      arg : Crystal::ASTNode,
      index : Int32,
      method_name : String,
      expected_types : Array(String),
      actual_type : String,
    )
      location = arg.location
      return unless location

      line_number = location.line_number - 1
      column_number = location.column_number - 1
      return if line_number < 0 || column_number < 0

      range = LSP::Range.new(
        LSP::Position.new(line_number, column_number),
        LSP::Position.new(line_number, column_number + 1)
      )

      expected = expected_types.join(" or ")
      message = "expected argument ##{index + 1} to '#{method_name}' to be #{expected}, not #{actual_type}"

      diagnostics << LSP::Diagnostic.new(
        range,
        message,
        LSP::DiagnosticSeverity::Error,
        "crystal"
      )
    end

    private def literal_type(node : Crystal::ASTNode) : String?
      case node
      when Crystal::StringLiteral
        "String"
      when Crystal::SymbolLiteral
        "Symbol"
      when Crystal::BoolLiteral
        "Bool"
      when Crystal::CharLiteral
        "Char"
      when Crystal::NilLiteral
        "Nil"
      when Crystal::NumberLiteral
        "Number"
      when Crystal::ArrayLiteral
        "Array"
      when Crystal::HashLiteral
        "Hash"
      when Crystal::RegexLiteral
        "Regex"
      end
    end

    private def types_compatible?(expected : String, actual : String) : Bool
      return true if expected == actual
      return true if actual == "Number" && NUMERIC_TYPES.includes?(expected)
      return true if expected == "Number" && NUMERIC_TYPES.includes?(actual)
      return true if expected == "Int" && (actual.starts_with?("Int") || actual.starts_with?("UInt"))
      return true if expected == "UInt" && actual.starts_with?("UInt")
      return true if expected == "Float" && (actual == "Float32" || actual == "Float64")

      false
    end
  end
end
