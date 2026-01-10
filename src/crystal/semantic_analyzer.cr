require "../lsp/protocol"
require "./workspace_analyzer"
require "compiler/crystal/syntax"
require "uri"
require "yaml"

module Liger
  class SemanticAnalyzer
    property workspace_root : String?
    property enable_semantic_hover : Bool = true
    property enable_type_aware_completion : Bool = true

    @sources = Hash(String, String).new
    @last_saved_hashes = Hash(String, UInt64).new
    @cache_dir : String?
    @main_file_cache : String?
    @main_file_cache_time : Time?
    @workspace_analyzer : WorkspaceAnalyzer

    def initialize(@workspace_root : String? = nil)
      @workspace_analyzer = WorkspaceAnalyzer.new(@workspace_root)
      if @workspace_root
        workspace_path = uri_to_filename(@workspace_root.not_nil!)
        @cache_dir = File.join(workspace_path, ".liger-cache")
        Dir.mkdir_p(@cache_dir.not_nil!) unless Dir.exists?(@cache_dir.not_nil!)
      end
    end

    def update_source(uri : String, source : String)
      @sources[uri] = source
      @workspace_analyzer.update_source(uri, source)
    end

    def remove_source(uri : String)
      @sources.delete(uri)
    end

    def analyze(uri : String) : Array(LSP::Diagnostic)
      diagnostics = [] of LSP::Diagnostic

      source = @sources[uri]?
      return diagnostics unless source

      begin
        parser = ::Crystal::Parser.new(source)
        parser.filename = uri_to_filename(uri)
        node = parser.parse
      rescue ex : ::Crystal::SyntaxException
        line = ex.line_number - 1
        column = ex.column_number - 1

        range = LSP::Range.new(
          LSP::Position.new(line, column),
          LSP::Position.new(line, column + 1)
        )

        diagnostics << LSP::Diagnostic.new(
          range,
          ex.message || "Syntax error",
          LSP::DiagnosticSeverity::Error,
          "crystal"
        )
      rescue ex : Exception
        range = LSP::Range.new(
          LSP::Position.new(0, 0),
          LSP::Position.new(0, 1)
        )

        diagnostics << LSP::Diagnostic.new(
          range,
          "Parse error: #{ex.message}",
          LSP::DiagnosticSeverity::Error,
          "crystal"
        )
      end

      diagnostics
    end

    def find_definition(uri : String, position : LSP::Position) : LSP::Location?
      source = @sources[uri]?
      return nil unless source

      lines = source.split('\n')
      return nil if position.line >= lines.size

      line_text = lines[position.line]
      word = extract_word_at_position(line_text, position.character)
      return nil unless word

      STDERR.puts "Find definition for: '#{word}' at #{position.line}:#{position.character}"

      if location = find_definition_in_current_file(source, word, uri)
        STDERR.puts "Found definition in current file"
        return location
      end

      if symbol = @workspace_analyzer.find_symbol_info(word)
        STDERR.puts "Found symbol in workspace: #{symbol.name} (#{symbol.kind}) in #{symbol.file}:#{symbol.line}"
        def_uri = filename_to_uri(symbol.file)
        range = LSP::Range.new(
          LSP::Position.new(symbol.line, 0),
          LSP::Position.new(symbol.line, word.size)
        )
        return LSP::Location.new(def_uri, range)
      end

      if word.starts_with?("@")
        if symbol = @workspace_analyzer.find_property_definition(word, uri, source)
          def_uri = filename_to_uri(symbol.file)
          range = LSP::Range.new(
            LSP::Position.new(symbol.line, 0),
            LSP::Position.new(symbol.line, symbol.name.size)
          )
          return LSP::Location.new(def_uri, range)
        end
      end

      if dot_pos = find_dot_in_line(line_text, position.character)
        receiver_word = extract_word_before_dot(line_text, dot_pos)
        if receiver_word
          receiver_type = @workspace_analyzer.get_type_at_position(
            uri,
            source,
            LSP::Position.new(position.line, dot_pos - 1)
          )
          if receiver_type
            symbol = @workspace_analyzer.find_method_definition(receiver_type, word)
            if symbol
              def_uri = filename_to_uri(symbol.file)
              range = LSP::Range.new(
                LSP::Position.new(symbol.line, 0),
                LSP::Position.new(symbol.line, symbol.name.size)
              )
              return LSP::Location.new(def_uri, range)
            end
          end
        end
      end

      filename = uri_to_filename(uri)
      line = position.line + 1
      column = position.character + 1

      begin
        cursor_loc = "#{filename}:#{line}:#{column}"

        output_io = IO::Memory.new
        error_io = IO::Memory.new
        main_file = find_main_file(filename)
        args = ["tool", "implementations", "-c", cursor_loc]
        args << main_file if main_file

        STDERR.puts "find_definition: cursor=#{cursor_loc}, main=#{main_file || "none"}"
        STDERR.puts "find_definition command: crystal #{args.join(" ")}"

        if source = @sources[uri]
          source_hash = source.hash
          if @last_saved_hashes[uri]? != source_hash
            File.write(filename, source)
            @last_saved_hashes[uri] = source_hash
            STDERR.puts "Saved current file: #{filename}"
          else
            STDERR.puts "File unchanged, skipping save: #{filename}"
          end
        end

        Process.run("crystal", args,
          output: output_io,
          error: error_io)

        output = output_io.to_s
        error = error_io.to_s

        STDERR.puts "find_definition output: #{output}" unless output.empty?
        STDERR.puts "find_definition error: #{error}" unless error.empty?

        lines = output.split('\n')

        lines.each do |line|
          if match = line.match(/^(.+):(\d+):(\d+)/)
            def_file = match[1]
            def_line = match[2].to_i - 1
            def_col = match[3].to_i - 1

            def_uri = filename_to_uri(def_file)

            range = LSP::Range.new(
              LSP::Position.new(def_line, def_col),
              LSP::Position.new(def_line, def_col + 1)
            )

            return LSP::Location.new(def_uri, range)
          end
        end
      rescue ex
        STDERR.puts "Error finding definition: #{ex.message}"
      end

      nil
    end

    def find_references(
      uri : String,
      position : LSP::Position,
      include_declaration : Bool = false,
    ) : Array(LSP::Location)
      [] of LSP::Location
    end

    def hover(uri : String, position : LSP::Position) : LSP::Hover?
      source = @sources[uri]?
      return nil unless source

      if hover_info = get_hover_from_workspace(uri, source, position)
        return hover_info
      end

      filename = uri_to_filename(uri)
      line = position.line + 1
      column = position.character + 1

      begin
        cursor_loc = "#{filename}:#{line}:#{column}"
        output_io = IO::Memory.new
        error_io = IO::Memory.new

        if source = @sources[uri]
          source_hash = source.hash
          if @last_saved_hashes[uri]? != source_hash
            File.write(filename, source)
            @last_saved_hashes[uri] = source_hash
          end
        end

        main_file = find_main_file(filename)
        args = ["tool", "context", "-c", cursor_loc]
        args << main_file if main_file

        Process.run("crystal", args, output: output_io, error: error_io)

        output = output_io.to_s

        if !output.empty? && !output.includes?("Error") &&
           !output.includes?("Usage:") &&
           !output.includes?("no context")
          content = "```crystal\n#{output.strip}\n```"
          return LSP::Hover.new(LSP::MarkupContent.new("markdown", content))
        end
      rescue ex
        STDERR.puts "Error getting hover info: #{ex.message}"
      end

      lines = source.split('\n')
      return nil if position.line >= lines.size

      line_text = lines[position.line]
      word = extract_word_at_position(line_text, position.character)

      if word && !word.empty?
        content = "**#{word}**\n\n*Type information not available*"
        return LSP::Hover.new(LSP::MarkupContent.new("markdown", content))
      end

      nil
    end

    def signature_help(uri : String, position : LSP::Position) : LSP::SignatureHelp?
      nil
    end

    def completions(uri : String, position : LSP::Position) : Array(LSP::CompletionItem)
      items = [] of LSP::CompletionItem

      source = @sources[uri]?
      return items unless source

      lines = source.split('\n')
      return items if position.line >= lines.size

      line = lines[position.line]
      prefix = line[0...position.character]

      STDERR.puts "Completion request: line='#{line}', prefix='#{prefix}', pos=#{position.character}"

      if match = prefix.match(/([\w@]+)\.([\w]*)$/)
        receiver = match[1]
        partial_method = match[2]

        STDERR.puts "Dot completion: receiver='#{receiver}', partial='#{partial_method}'"

        receiver_pos = LSP::Position.new(position.line, position.character - partial_method.size - 1)
        if receiver_type = @workspace_analyzer.get_type_at_position(uri, source, receiver_pos)
          STDERR.puts "Found receiver type: #{receiver_type}"
          completions = @workspace_analyzer.get_completions_for_receiver(receiver_type)
          completions.each do |method_name|
            if method_name.starts_with?(partial_method)
              items << LSP::CompletionItem.new(
                method_name,
                LSP::CompletionItemKind::Method,
                "#{receiver_type} method"
              )
            end
          end
        else
          STDERR.puts "No receiver type found, trying variable inference"
          if receiver_type = find_variable_type_in_source(source, receiver, position.line)
            STDERR.puts "Inferred receiver type: #{receiver_type}"
            completions = @workspace_analyzer.get_completions_for_receiver(receiver_type)
            completions.each do |method_name|
              if method_name.starts_with?(partial_method)
                items << LSP::CompletionItem.new(
                  method_name,
                  LSP::CompletionItemKind::Method,
                  "#{receiver_type} method"
                )
              end
            end
          end
        end

        add_common_method_completions(items)
        filename = uri_to_filename(uri)
        line_num = position.line + 1
        col_num = position.character - 1

        begin
          cursor_loc = "#{filename}:#{line_num}:#{col_num}"

          output_io = IO::Memory.new
          error_io = IO::Memory.new

          Process.run("crystal", ["tool", "context", "-c", cursor_loc, filename],
            output: output_io,
            error: error_io)

          context_output = output_io.to_s

          if !context_output.empty? &&
             !context_output.includes?("Error") &&
             !context_output.includes?("Usage:")
            add_type_aware_completions(items, context_output)
          end
        rescue
        end
      elsif prefix =~ /::/
        add_type_completions(items)
      else
        add_keyword_completions(items)
        add_type_completions(items)
        add_file_symbol_completions(items, source)
        add_workspace_symbol_completions(items)
      end

      STDERR.puts "Returning #{items.size} completion items"
      items
    end

    def prepare_rename(uri : String, position : LSP::Position) : LSP::Range?
      nil
    end

    def rename(uri : String, position : LSP::Position, new_name : String) : LSP::WorkspaceEdit?
      source = @sources[uri]?
      return nil unless source

      lines = source.split('\n')
      return nil if position.line >= lines.size

      line = lines[position.line]
      char = position.character
      return nil if char < 0 || char > line.size

      start_pos = char
      while start_pos > 0 && word_char?(line[start_pos - 1])
        start_pos -= 1
      end

      end_pos = char
      while end_pos < line.size && word_char?(line[end_pos])
        end_pos += 1
      end

      return nil if start_pos == end_pos

      old_name = line[start_pos...end_pos]

      edits = [] of LSP::TextEdit

      lines.each_with_index do |line, line_num|
        offset = 0
        while (index = line.index(old_name, offset))
          before_ok = index == 0 || !word_char?(line[index - 1])
          after_ok = index + old_name.size >= line.size || !word_char?(line[index + old_name.size])

          if before_ok && after_ok
            range = LSP::Range.new(
              LSP::Position.new(line_num, index),
              LSP::Position.new(line_num, index + old_name.size)
            )
            edits << LSP::TextEdit.new(range, new_name)
          end

          offset = index + 1
        end
      end

      return nil if edits.empty?

      changes = {uri => edits}
      LSP::WorkspaceEdit.new(changes)
    end

    private def word_char?(char : Char) : Bool
      char.alphanumeric? || char == '_' || char == '?' || char == '!'
    end

    private def add_keyword_completions(items : Array(LSP::CompletionItem))
      keywords = [
        "abstract", "alias", "annotation", "as", "as?", "asm", "begin", "break",
        "case", "class", "def", "do", "else", "elsif", "end", "ensure", "enum",
        "extend", "false", "for", "fun", "if", "include", "instance_sizeof",
        "is_a?", "lib", "macro", "module", "next", "nil", "nil?", "of", "out",
        "pointerof", "private", "protected", "require", "rescue", "responds_to?",
        "return", "select", "self", "sizeof", "struct", "super", "then", "true",
        "type", "typeof", "uninitialized", "union", "unless", "until", "verbatim",
        "when", "while", "with", "yield",
      ]

      keywords.each do |keyword|
        items << LSP::CompletionItem.new(
          keyword,
          LSP::CompletionItemKind::Keyword,
          "Crystal keyword"
        )
      end
    end

    private def add_type_completions(items : Array(LSP::CompletionItem))
      types = [
        "String", "Int32", "Int64", "Float64", "Bool", "Array", "Hash",
        "Nil", "Symbol", "Char", "Tuple", "NamedTuple", "Range", "Regex",
        "Time", "JSON", "YAML", "File", "Dir", "Process", "Channel",
        "Exception", "IO", "Path", "Set", "Slice", "Pointer", "Proc",
      ]

      types.each do |type|
        items << LSP::CompletionItem.new(
          type,
          LSP::CompletionItemKind::Class,
          "Crystal type"
        )
      end
    end

    private def uri_to_filename(uri : String) : String
      return uri unless uri.starts_with?("file://")

      filename = uri.sub(/^file:\/\//, "")
      filename = URI.decode(filename)

      if filename =~ /^\/([a-zA-Z]):/
        filename = filename[1..]
      end

      filename.gsub('/', '\\')
    end

    private def filename_to_uri(filename : String) : String
      path = filename.gsub('\\', '/')

      if path =~ /^([a-zA-Z]):/
        drive = path[0].to_s
        rest = path[2..]
        path = "#{drive}%3A#{rest}"
      end

      "file:///#{path}"
    end

    private def find_main_file(current_file : String) : String?
      return nil unless @workspace_root

      if @main_file_cache && @main_file_cache_time
        if (Time.utc - @main_file_cache_time.not_nil!).total_seconds < 5
          return @main_file_cache
        end
      end

      workspace_path = uri_to_filename(@workspace_root.not_nil!)
      shard_yml = File.join(workspace_path, "shard.yml")
      result : String? = nil

      if File.exists?(shard_yml)
        begin
          yaml = YAML.parse(File.read(shard_yml))

          if targets = yaml["targets"]?
            targets.as_h.each do |name, config|
              if main_path = config["main"]?
                normalized_main = main_path.as_s.gsub('/', '\\')
                main_file = File.join(workspace_path, normalized_main)
                if File.exists?(main_file)
                  result = main_file
                  break
                else
                  STDERR.puts " Main file does not exist: #{main_file}"
                end
              end
            end
          else
            STDERR.puts "No targets section found in shard.yml"
          end
        rescue ex
          STDERR.puts "Error parsing shard.yml: #{ex.message}"
        end
      else
        STDERR.puts "shard.yml not found"
      end

      unless result
        STDERR.puts "Trying fallback candidates..."
        candidates = [
          File.join(workspace_path, "src", File.basename(workspace_path) + ".cr"),
          File.join(workspace_path, "src", "main.cr"),
          File.join(workspace_path, "main.cr"),
        ]

        candidates.each do |candidate|
          STDERR.puts "  Checking: #{candidate}"
          if File.exists?(candidate)
            STDERR.puts "  Found: #{candidate}"
            result = candidate
            break
          end
        end
      end

      @main_file_cache = result
      @main_file_cache_time = Time.utc

      STDERR.puts result ? "Main file: #{result}" : "No main file found"
      result
    rescue ex
      STDERR.puts "Exception in find_main_file: #{ex.message}"
      nil
    end

    private def extract_word_at_position(line : String, char : Int32) : String?
      return nil if char < 0 || char > line.size
      start_pos = char
      while start_pos > 0 && word_char?(line[start_pos - 1])
        start_pos -= 1
      end

      end_pos = char
      while end_pos < line.size && word_char?(line[end_pos])
        end_pos += 1
      end

      return nil if start_pos == end_pos
      line[start_pos...end_pos]
    end

    private def add_type_aware_completions(items : Array(LSP::CompletionItem), context_output : String)
      if match = context_output.match(/(\w+)#(\w+)/)
        type_name = match[1]
      end
    end

    private def add_type_specific_completions(
      items : Array(LSP::CompletionItem),
      type_name : String,
      partial : String,
    )
      case type_name
      when "String"
        string_methods = [
          {"size", "String length", LSP::CompletionItemKind::Method},
          {"empty?", "Check if empty", LSP::CompletionItemKind::Method},
          {"upcase", "Convert to uppercase", LSP::CompletionItemKind::Method},
          {"downcase", "Convert to lowercase", LSP::CompletionItemKind::Method},
          {"strip", "Remove whitespace", LSP::CompletionItemKind::Method},
          {"split", "Split into array", LSP::CompletionItemKind::Method},
          {"starts_with?", "Check prefix", LSP::CompletionItemKind::Method},
          {"ends_with?", "Check suffix", LSP::CompletionItemKind::Method},
          {"includes?", "Check substring", LSP::CompletionItemKind::Method},
          {"chars", "Get array of characters", LSP::CompletionItemKind::Method},
          {"gsub", "Global substitution", LSP::CompletionItemKind::Method},
          {"match", "Regex match", LSP::CompletionItemKind::Method},
        ]
        string_methods.each do |name, detail, kind|
          if name.starts_with?(partial)
            items << LSP::CompletionItem.new(name, kind, detail)
          end
        end
      when "Array"
        array_methods = [
          {"each", "Iterate over elements", LSP::CompletionItemKind::Method},
          {"map", "Transform elements", LSP::CompletionItemKind::Method},
          {"select", "Filter elements", LSP::CompletionItemKind::Method},
          {"reject", "Reject elements", LSP::CompletionItemKind::Method},
          {"first", "Get first element", LSP::CompletionItemKind::Method},
          {"last", "Get last element", LSP::CompletionItemKind::Method},
          {"push", "Add element", LSP::CompletionItemKind::Method},
          {"pop", "Remove last element", LSP::CompletionItemKind::Method},
          {"sort", "Sort elements", LSP::CompletionItemKind::Method},
          {"size", "Array size", LSP::CompletionItemKind::Method},
          {"empty?", "Check if empty", LSP::CompletionItemKind::Method},
        ]
        array_methods.each do |name, detail, kind|
          if name.starts_with?(partial)
            items << LSP::CompletionItem.new(name, kind, detail)
          end
        end
      when "Hash"
        hash_methods = [
          {"each", "Iterate over key-value pairs", LSP::CompletionItemKind::Method},
          {"keys", "Get all keys", LSP::CompletionItemKind::Method},
          {"values", "Get all values", LSP::CompletionItemKind::Method},
          {"has_key?", "Check if key exists", LSP::CompletionItemKind::Method},
          {"size", "Hash size", LSP::CompletionItemKind::Method},
          {"empty?", "Check if empty", LSP::CompletionItemKind::Method},
        ]
        hash_methods.each do |name, detail, kind|
          if name.starts_with?(partial)
            items << LSP::CompletionItem.new(name, kind, detail)
          end
        end
      end
    end

    private def find_variable_type_in_source(
      source : String,
      var_name : String,
      current_line : Int32,
    ) : String?
      lines = source.split('\n')

      (0...current_line).reverse_each do |line_num|
        line = lines[line_num]

        if match = line.match(/#{Regex.escape(var_name)}\s*:\s*(\w+)\s*=/)
          return match[1]
        end
        if match = line.match(/#{Regex.escape(var_name)}\s*=\s*(.+)/)
          assignment = match[1].strip
          return infer_type_from_assignment(assignment)
        end
      end

      nil
    end

    private def infer_type_from_assignment(value : String) : String
      value = value.strip

      return "String" if value.starts_with?('"') || value.starts_with?("'")
      return "Int32" if value.match(/^\d+$/)
      return "Float64" if value.match(/^\d+\.\d+$/)
      return "Bool" if value == "true" || value == "false"
      return "Nil" if value == "nil"
      return "Array" if value.starts_with?('[')
      return "Hash" if value.starts_with?('{')
      return "Regex" if value.starts_with?('/')

      if match = value.match(/(\w+)\.(\w+)/)
        method = match[2]
        case method
        when "to_s"           then return "String"
        when "to_i"           then return "Int32"
        when "to_f"           then return "Float64"
        when "size", "length" then return "Int32"
        when "empty?"         then return "Bool"
        when "split"          then return "Array(String)"
        when "chars"          then return "Array(Char)"
        end
      end

      if match = value.match(/(\w+)\.new/)
        return match[1]
      end

      "Object"
    end

    private def get_hover_from_workspace(uri : String, source : String, position : LSP::Position) : LSP::Hover?
      lines = source.split('\n')
      return nil if position.line >= lines.size

      line_text = lines[position.line]
      word = extract_word_at_position(line_text, position.character)
      return nil unless word

      if signature = find_signature_in_current_file(source, word)
        content = "```crystal\n#{signature}\n```"
        return LSP::Hover.new(LSP::MarkupContent.new("markdown", content))
      end

      if symbol = @workspace_analyzer.find_symbol_info(word)
        content = case symbol.kind
                  when "method"
                    if signature = symbol.signature
                      "```crystal\n#{signature}\n```"
                    else
                      "```crystal\ndef #{symbol.name} : #{symbol.type}\n```"
                    end
                  when "class"
                    "```crystal\nclass #{symbol.name} < #{symbol.type}\n```"
                  when "module"
                    "```crystal\nmodule #{symbol.name}\n```"
                  when "enum"
                    "```crystal\nenum #{symbol.name}\n```"
                  when "struct"
                    "```crystal\nstruct #{symbol.name}\n```"
                  when "property", "getter", "setter"
                    "```crystal\n#{symbol.kind} #{symbol.name.sub("@", "")} : #{symbol.type}\n```"
                  when "instance_variable"
                    "```crystal\n#{symbol.name} : #{symbol.type}\n```"
                  when "constant"
                    "```crystal\n#{symbol.name} : #{symbol.type}\n```"
                  when "alias"
                    "```crystal\nalias #{symbol.name} = #{symbol.type}\n```"
                  else
                    "```crystal\n#{symbol.name} : #{symbol.type}\n```"
                  end

        return LSP::Hover.new(LSP::MarkupContent.new("markdown", content))
      end

      if type_info = @workspace_analyzer.get_type_at_position(uri, source, position)
        content = "```crystal\n#{word} : #{type_info}\n```"
        return LSP::Hover.new(LSP::MarkupContent.new("markdown", content))
      end

      nil
    end

    private def find_signature_in_current_file(source : String, method_name : String) : String?
      lines = source.split('\n')

      lines.each_with_index do |line, line_num|
        if match = line.match(/^\s*((?:private\s+)?def\s+#{Regex.escape(method_name)}\s*(?:\([^)]*\))?\s*(?::\s*\w+)?)/)
          signature = match[1].strip

          if line.ends_with?("\\") || (!line.includes?(")") && line.includes?("("))
            full_signature = signature
            (line_num + 1...lines.size).each do |i|
              next_line = lines[i].strip
              full_signature += " " + next_line
              break if next_line.includes?(")")
              break if i > line_num + 5
            end
            return full_signature
          end

          return signature
        end

        if match = line.match(/^\s*(class\s+#{Regex.escape(method_name)}(?:\s*<\s*\w+)?)/)
          return match[1].strip
        end

        if match = line.match(/^\s*(module\s+#{Regex.escape(method_name)})/)
          return match[1].strip
        end

        if match = line.match(/^\s*(enum\s+#{Regex.escape(method_name)})/)
          return match[1].strip
        end

        if match = line.match(/^\s*(struct\s+#{Regex.escape(method_name)})/)
          return match[1].strip
        end

        if match = line.match(/^\s*((?:property|getter|setter)\s+#{Regex.escape(method_name.sub("@", ""))}\s*:\s*\w+)/)
          return match[1].strip
        end

        if match = line.match(/^\s*(#{Regex.escape(method_name)}\s*=\s*.+)/)
          return match[1].strip
        end

        if match = line.match(/^\s*(alias\s+#{Regex.escape(method_name)}\s*=\s*.+)/)
          return match[1].strip
        end
      end

      nil
    end

    private def find_definition_in_current_file(
      source : String,
      symbol_name : String,
      uri : String,
    ) : LSP::Location?
      lines = source.split('\n')

      lines.each_with_index do |line, line_num|
        # Method definitions
        if match = line.match(/^\s*def\s+(#{Regex.escape(symbol_name)})(?:\(|$|\s)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Private method definitions
        if match = line.match(/^\s*private\s+def\s+(#{Regex.escape(symbol_name)})(?:\(|$|\s)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Class definitions
        if match = line.match(/^\s*class\s+(#{Regex.escape(symbol_name)})(?:\s|$)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Module definitions
        if match = line.match(/^\s*module\s+(#{Regex.escape(symbol_name)})(?:\s|$)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Enum definitions
        if match = line.match(/^\s*enum\s+(#{Regex.escape(symbol_name)})(?:\s|$)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Struct definitions
        if match = line.match(/^\s*struct\s+(#{Regex.escape(symbol_name)})(?:\s|$)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Alias definitions
        if match = line.match(/^\s*alias\s+(#{Regex.escape(symbol_name)})(?:\s|$)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Constants
        if match = line.match(/^\s*(#{Regex.escape(symbol_name)})\s*=/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Property declarations
        if match = line.match(/^\s*(?:property|getter|setter)\s+(#{Regex.escape(symbol_name.sub("@", ""))})(?:\s|$)/)
          range = LSP::Range.new(
            LSP::Position.new(line_num, match.begin(1).not_nil!),
            LSP::Position.new(line_num, match.end(1).not_nil!)
          )
          return LSP::Location.new(uri, range)
        end

        # Instance variables
        if symbol_name.starts_with?("@")
          if match = line.match(/(#{Regex.escape(symbol_name)})\s*:/)
            range = LSP::Range.new(
              LSP::Position.new(line_num, match.begin(1).not_nil!),
              LSP::Position.new(line_num, match.end(1).not_nil!)
            )
            return LSP::Location.new(uri, range)
          end
        end
      end

      nil
    end

    private def find_dot_in_line(line : String, pos : Int32) : Int32?
      (0...pos).reverse_each do |i|
        return i if line[i] == '.'
        break unless line[i].whitespace?
      end
      nil
    end

    private def extract_word_before_dot(line : String, dot_pos : Int32) : String?
      return nil if dot_pos <= 0

      end_pos = dot_pos - 1
      while end_pos >= 0 && line[end_pos].whitespace?
        end_pos -= 1
      end
      return nil if end_pos < 0

      start_pos = end_pos
      while start_pos > 0 && word_char?(line[start_pos - 1])
        start_pos -= 1
      end

      return nil if start_pos == end_pos + 1
      line[start_pos..end_pos]
    end

    private def add_workspace_symbol_completions(items : Array(LSP::CompletionItem))
      if symbol = @workspace_analyzer.find_symbol_info("")
      end
    end

    private def add_common_method_completions(items : Array(LSP::CompletionItem))
      common_methods = [
        {"to_s", "Convert to String", LSP::CompletionItemKind::Method},
        {"to_i", "Convert to Int32", LSP::CompletionItemKind::Method},
        {"to_f", "Convert to Float64", LSP::CompletionItemKind::Method},
        {"inspect", "Debug representation", LSP::CompletionItemKind::Method},
        {"class", "Get object class", LSP::CompletionItemKind::Method},
        {"nil?", "Check if nil", LSP::CompletionItemKind::Method},
        {"is_a?", "Check type", LSP::CompletionItemKind::Method},
        {"as", "Type cast", LSP::CompletionItemKind::Method},
        {"size", "Get size/length", LSP::CompletionItemKind::Method},
        {"empty?", "Check if empty", LSP::CompletionItemKind::Method},
        {"each", "Iterate elements", LSP::CompletionItemKind::Method},
        {"map", "Transform elements", LSP::CompletionItemKind::Method},
        {"select", "Filter elements", LSP::CompletionItemKind::Method},
        {"reject", "Reject elements", LSP::CompletionItemKind::Method},
        {"first", "Get first element", LSP::CompletionItemKind::Method},
        {"last", "Get last element", LSP::CompletionItemKind::Method},
        {"upcase", "Convert to uppercase", LSP::CompletionItemKind::Method},
        {"downcase", "Convert to lowercase", LSP::CompletionItemKind::Method},
        {"strip", "Remove whitespace", LSP::CompletionItemKind::Method},
        {"split", "Split string", LSP::CompletionItemKind::Method},
        {"join", "Join array", LSP::CompletionItemKind::Method},
        {"includes?", "Check if includes", LSP::CompletionItemKind::Method},
        {"starts_with?", "Check prefix", LSP::CompletionItemKind::Method},
        {"ends_with?", "Check suffix", LSP::CompletionItemKind::Method},
      ]

      common_methods.each do |name, detail, kind|
        items << LSP::CompletionItem.new(name, kind, detail)
      end
    end

    private def add_file_symbol_completions(items : Array(LSP::CompletionItem), source : String)
      begin
        parser = Crystal::Parser.new(source)
        node = parser.parse
        extract_symbols_for_completion(node, items)
      rescue
      end
    end

    private def extract_symbols_for_completion(node : Crystal::ASTNode, items : Array(LSP::CompletionItem))
      case node
      when Crystal::ClassDef
        items << LSP::CompletionItem.new(
          node.name.to_s,
          LSP::CompletionItemKind::Class,
          "Class"
        )
        node.body.try { |body| extract_symbols_for_completion(body, items) }
      when Crystal::ModuleDef
        items << LSP::CompletionItem.new(
          node.name.to_s,
          LSP::CompletionItemKind::Module,
          "Module"
        )
        node.body.try { |body| extract_symbols_for_completion(body, items) }
      when Crystal::Def
        items << LSP::CompletionItem.new(
          node.name,
          LSP::CompletionItemKind::Method,
          "Method"
        )
      when Crystal::Assign
        if target = node.target
          if target.is_a?(Crystal::Var)
            items << LSP::CompletionItem.new(
              target.name,
              LSP::CompletionItemKind::Variable,
              "Variable"
            )
          end
        end
      when Crystal::Expressions
        node.expressions.each { |expr| extract_symbols_for_completion(expr, items) }
      end
    end
  end
end
