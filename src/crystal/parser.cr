require "../lsp/protocol"
require "compiler/crystal/syntax"

module Liger
  # Crystal source code parser and analyzer wrapper
  class CrystalParser
    property source : String
    property uri : String

    def initialize(@uri : String, @source : String)
    end

    # Parse and return diagnostics
    def diagnostics : Array(LSP::Diagnostic)
      diagnostics = [] of LSP::Diagnostic

      begin
        # Use Crystal's built-in parser
        parser = ::Crystal::Parser.new(@source)
        parser.filename = @uri
        node = parser.parse
        
        # Check for syntax errors
        # Crystal parser will raise on syntax errors
      rescue ex : ::Crystal::SyntaxException
        # Convert Crystal syntax error to LSP diagnostic
        line = ex.line_number - 1 # LSP is 0-indexed
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
        # Generic error
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

    # Find definition of symbol at position
    def find_definition(position : LSP::Position) : LSP::Location?
      # This would require semantic analysis
      # For now, return nil
      nil
    end

    # Find references to symbol at position
    def find_references(position : LSP::Position, include_declaration : Bool = false) : Array(LSP::Location)
      # This would require semantic analysis
      [] of LSP::Location
    end

    # Get hover information at position
    def hover(position : LSP::Position) : LSP::Hover?
      # This would require semantic analysis
      nil
    end

    # Get completions at position
    def completions(position : LSP::Position) : Array(LSP::CompletionItem)
      items = [] of LSP::CompletionItem

      # Add Crystal keywords
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

      # Add common types
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

      items
    end

    # Get document symbols
    def document_symbols : Array(LSP::DocumentSymbol)
      symbols = [] of LSP::DocumentSymbol

      begin
        parser = ::Crystal::Parser.new(@source)
        parser.filename = @uri
        node = parser.parse
        
        # Extract symbols from AST
        extract_symbols(node, symbols)
      rescue ex : Exception
        # If parsing fails, return empty array
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

      # Extract child symbols
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
