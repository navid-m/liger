require "../lsp/protocol"
require "compiler/crystal/syntax"

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
      # TODO: This requires full semantic analysis with type information
      # Implementation would need to:
      # 1. Parse and type-check the code
      # 2. Find the symbol at the given position
      # 3. Resolve the symbol to its definition
      # 4. Return the location      
      nil
    end

    # Find all references to symbol at position
    def find_references(uri : String, position : LSP::Position, include_declaration : Bool = false) : Array(LSP::Location)
      # TODO: This requires full semantic analysis
      # Implementation would need to:
      # 1. Find the symbol at the position
      # 2. Search all files for references to that symbol
      # 3. Return all locations
      
      [] of LSP::Location
    end

    # Get hover information for symbol at position
    def hover(uri : String, position : LSP::Position) : LSP::Hover?
      # TODO: This requires type information
      # Implementation would show:
      # - Type of the symbol
      # - Documentation
      # - Signature (for methods)
      
      nil
    end

    # Get signature help at position
    def signature_help(uri : String, position : LSP::Position) : LSP::SignatureHelp?
      # TODO: This requires parsing and finding the current method call
      # Implementation would:
      # 1. Find the method call at the position
      # 2. Get the method signature(s)
      # 3. Determine which parameter is active
      
      nil
    end

    # Get completions at position
    def completions(uri : String, position : LSP::Position) : Array(LSP::CompletionItem)
      items = [] of LSP::CompletionItem
      
      source = @sources[uri]?
      return items unless source

      lines = source.split('\n')
      return items if position.line >= lines.size
      
      line = lines[position.line]
      prefix = line[0...position.character]

      if prefix =~ /\.(\w*)$/
        # This would require type information
      elsif prefix =~ /::/
        # This would require semantic analysis
      else
        # Add keywords, types, and local variables
        add_keyword_completions(items)
        add_type_completions(items)
      end

      items
    end

    # Prepare rename (check if symbol can be renamed)
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
      if uri.starts_with?("file://")
        path = uri[7..]
        if path =~ /^\/([a-zA-Z]):(.+)/
          "#{$1}:#{$2}"
        else
          path
        end
      else
        uri
      end
    end
  end
end
