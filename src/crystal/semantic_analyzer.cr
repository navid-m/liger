require "../lsp/protocol"
require "compiler/crystal/syntax"
require "uri"

module Liger
  class SemanticAnalyzer
    property workspace_root : String?
    @sources = Hash(String, String).new

    def initialize(@workspace_root : String? = nil)
    end

    def update_source(uri : String, source : String)
      @sources[uri] = source
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
      filename = uri_to_filename(uri)
      line = position.line + 1
      column = position.character + 1
      
      begin
        cursor_loc = "#{filename}:#{line}:#{column}"
        
        output_io = IO::Memory.new
        error_io = IO::Memory.new
        
        Process.run("crystal", ["tool", "implementations", "-c", cursor_loc, filename],
                   output: output_io,
                   error: error_io)
        
        output = output_io.to_s
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

    def find_references(uri : String, position : LSP::Position, include_declaration : Bool = false) : Array(LSP::Location)
      [] of LSP::Location
    end

    # Get hover information for symbol at position
    def hover(uri : String, position : LSP::Position) : LSP::Hover?
      filename = uri_to_filename(uri)
      line = position.line + 1
      column = position.character + 1
      
      begin
        cursor_loc = "#{filename}:#{line}:#{column}"
        
        output_io = IO::Memory.new
        error_io = IO::Memory.new
        
        Process.run("crystal", ["tool", "context", "-c", cursor_loc, filename],
                   output: output_io,
                   error: error_io)
        
        output = output_io.to_s
        error = error_io.to_s
        
        if !output.empty? && !output.includes?("Error") && !output.includes?("Usage:")
          content = "```crystal\n#{output.strip}\n```"
          return LSP::Hover.new(LSP::MarkupContent.new("markdown", content))
        end
      rescue ex
        STDERR.puts "Error getting hover info: #{ex.message}"
      end
      
      source = @sources[uri]?
      return nil unless source
      
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

      if match = prefix.match(/([\w@]+)\.([\w]*)$/)
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
          
          if !context_output.empty? && !context_output.includes?("Error") && !context_output.includes?("Usage:")
            add_type_aware_completions(items, context_output)
          end
        rescue
        end
        add_common_method_completions(items)
      elsif prefix =~ /::/
        add_type_completions(items)
      else
        add_keyword_completions(items)
        add_type_completions(items)
        add_file_symbol_completions(items, source)
      end

      items
    end

    def prepare_rename(uri : String, position : LSP::Position) : LSP::Range?
      nil
    end

    # Perform rename
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
        "when", "while", "with", "yield"
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
        "Exception", "IO", "Path", "Set", "Slice", "Pointer", "Proc"
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
        # Ignore parse errors
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
