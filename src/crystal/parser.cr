require "../lsp/protocol"
require "compiler/crystal/syntax"

module Liger
  # Source code parser and analyzer wrapper
  class CrystalParser
    property source : String
    property uri : String

    def initialize(@uri : String, @source : String)
    end

    # Parse and return diagnostics
    def diagnostics : Array(LSP::Diagnostic)
      diagnostics = [] of LSP::Diagnostic

      begin
        parser = ::Crystal::Parser.new(@source)
        parser.filename = @uri
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

    def find_definition(position : LSP::Position) : LSP::Location?
      nil
    end

    # Find references to symbol at position
    def find_references(position : LSP::Position, include_declaration : Bool = false) : Array(LSP::Location)
      [] of LSP::Location
    end

    # Get hover information at position
    def hover(position : LSP::Position) : LSP::Hover?
      nil
    end

    # Get completions at position
    def completions(position : LSP::Position) : Array(LSP::CompletionItem)
      items = [] of LSP::CompletionItem
      lines = @source.split('\n')
      line = lines[position.line]? || ""
      char = position.character
      
      if char > 0 && line[char - 1]? == '.'
        add_common_methods(items)
      else
        add_keywords(items)
        add_types(items)
        add_file_symbols(items)
      end

      items
    end

    private def add_keywords(items : Array(LSP::CompletionItem))
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

    private def add_types(items : Array(LSP::CompletionItem))
      types = [
        "String", "Int32", "Int64", "Float64", "Bool", "Array", "Hash",
        "Nil", "Symbol", "Char", "Tuple", "NamedTuple", "Range", "Regex",
        "Time", "JSON", "YAML", "File", "Dir", "Process", "Channel"
      ]

      types.each do |type|
        items << LSP::CompletionItem.new(
          type,
          LSP::CompletionItemKind::Class,
          "Crystal type"
        )
      end
    end

    # Add common methods that work on most objects
    private def add_common_methods(items : Array(LSP::CompletionItem))
      common = [
        {"to_s", "Convert to String"},
        {"to_i", "Convert to Int32"},
        {"to_f", "Convert to Float64"},
        {"inspect", "Return debug representation"},
        {"class", "Return object class"},
        {"nil?", "Check if nil"},
        {"is_a?", "Check type"},
        {"responds_to?", "Check if responds to method"},
      ]

      string_methods = [
        {"size", "String length"},
        {"empty?", "Check if empty"},
        {"upcase", "Convert to uppercase"},
        {"downcase", "Convert to lowercase"},
        {"strip", "Remove whitespace"},
        {"split", "Split into array"},
        {"starts_with?", "Check prefix"},
        {"ends_with?", "Check suffix"},
        {"includes?", "Check substring"},
        {"chars", "Get array of characters"},
      ]

      array_methods = [
        {"each", "Iterate over elements"},
        {"map", "Transform elements"},
        {"select", "Filter elements"},
        {"reject", "Reject elements"},
        {"first", "Get first element"},
        {"last", "Get last element"},
        {"push", "Add element"},
        {"pop", "Remove last element"},
        {"sort", "Sort elements"},
      ]

      (common + string_methods + array_methods).each do |method, desc|
        items << LSP::CompletionItem.new(
          method,
          LSP::CompletionItemKind::Method,
          desc
        )
      end
    end

    # Add symbols from current file
    private def add_file_symbols(items : Array(LSP::CompletionItem))
      begin
        parser = ::Crystal::Parser.new(@source)
        parser.filename = @uri
        node = parser.parse
        extract_completions(node, items)
      rescue
      end
    end

    private def extract_completions(node : ::Crystal::ASTNode, items : Array(LSP::CompletionItem))
      case node
      when ::Crystal::ClassDef
        items << LSP::CompletionItem.new(
          node.name.to_s,
          LSP::CompletionItemKind::Class,
          "Class defined in this file"
        )
        node.body.try { |body| extract_completions(body, items) }
      when ::Crystal::ModuleDef
        items << LSP::CompletionItem.new(
          node.name.to_s,
          LSP::CompletionItemKind::Module,
          "Module defined in this file"
        )
        node.body.try { |body| extract_completions(body, items) }
      when ::Crystal::Def
        items << LSP::CompletionItem.new(
          node.name,
          LSP::CompletionItemKind::Method,
          "Method defined in this file"
        )
      when ::Crystal::Expressions
        node.expressions.each { |expr| extract_completions(expr, items) }
      end
    end

    # Get document symbols
    def document_symbols : Array(LSP::DocumentSymbol)
      symbols = [] of LSP::DocumentSymbol

      begin
        parser = ::Crystal::Parser.new(@source)
        parser.filename = @uri
        node = parser.parse
        extract_symbols(node, symbols)
      rescue ex : Exception
        puts "Ran into an error at document_syms, #{ex.message}"
      end

      symbols
    end

    private def extract_symbols(node : ::Crystal::ASTNode, symbols : Array(LSP::DocumentSymbol))
      case node
      when ::Crystal::ClassDef
        add_class_symbol(node, symbols)
      when ::Crystal::ModuleDef
        add_module_symbol(node, symbols)
      when ::Crystal::Def
        add_method_symbol(node, symbols)
      when ::Crystal::Assign
        add_variable_symbol(node, symbols)
      when ::Crystal::Expressions
        node.expressions.each { |expr| extract_symbols(expr, symbols) }
      end
    end

    private def add_class_symbol(node : ::Crystal::ClassDef, symbols : Array(LSP::DocumentSymbol))
      location = node.location
      return unless location

      start_pos = LSP::Position.new(location.line_number - 1, location.column_number - 1)
      end_location = node.end_location
      end_pos = end_location ? 
        LSP::Position.new(end_location.line_number - 1, end_location.column_number - 1) :
        LSP::Position.new(start_pos.line, start_pos.character + node.name.to_s.size)

      range = LSP::Range.new(start_pos, end_pos)
      selection_range = LSP::Range.new(start_pos, LSP::Position.new(start_pos.line, start_pos.character + node.name.to_s.size))

      symbol = LSP::DocumentSymbol.new(
        node.name.to_s,
        LSP::SymbolKind::Class,
        range,
        selection_range
      )

      children = [] of LSP::DocumentSymbol
      node.body.try { |body| extract_symbols(body, children) }
      symbol.children = children unless children.empty?
      symbols << symbol
    end

    private def add_module_symbol(node : ::Crystal::ModuleDef, symbols : Array(LSP::DocumentSymbol))
      location = node.location
      return unless location

      start_pos = LSP::Position.new(location.line_number - 1, location.column_number - 1)
      end_location = node.end_location
      end_pos = end_location ? 
        LSP::Position.new(end_location.line_number - 1, end_location.column_number - 1) :
        LSP::Position.new(start_pos.line, start_pos.character + node.name.to_s.size)

      range = LSP::Range.new(start_pos, end_pos)
      selection_range = LSP::Range.new(start_pos, LSP::Position.new(start_pos.line, start_pos.character + node.name.to_s.size))

      symbol = LSP::DocumentSymbol.new(
        node.name.to_s,
        LSP::SymbolKind::Module,
        range,
        selection_range
      )

      # Extract child symbols
      children = [] of LSP::DocumentSymbol
      node.body.try { |body| extract_symbols(body, children) }
      symbol.children = children unless children.empty?

      symbols << symbol
    end

    private def add_method_symbol(node : ::Crystal::Def, symbols : Array(LSP::DocumentSymbol))
      location = node.location
      return unless location

      start_pos = LSP::Position.new(location.line_number - 1, location.column_number - 1)
      end_location = node.end_location
      end_pos = end_location ? 
        LSP::Position.new(end_location.line_number - 1, end_location.column_number - 1) :
        LSP::Position.new(start_pos.line, start_pos.character + node.name.size)

      range = LSP::Range.new(start_pos, end_pos)
      selection_range = LSP::Range.new(start_pos, LSP::Position.new(start_pos.line, start_pos.character + node.name.size))

      symbols << LSP::DocumentSymbol.new(
        node.name,
        LSP::SymbolKind::Method,
        range,
        selection_range
      )
    end

    private def add_variable_symbol(node : ::Crystal::Assign, symbols : Array(LSP::DocumentSymbol))
      location = node.location
      return unless location

      target = node.target
      return unless target.is_a?(::Crystal::Var)

      start_pos = LSP::Position.new(location.line_number - 1, location.column_number - 1)
      end_pos = LSP::Position.new(start_pos.line, start_pos.character + target.name.size)
      range = LSP::Range.new(start_pos, end_pos)

      symbols << LSP::DocumentSymbol.new(
        target.name,
        LSP::SymbolKind::Variable,
        range,
        range
      )
    end
  end
end
