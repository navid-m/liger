require "./protocol"

module LSP
  # Manages text documents and provides methods to open, close, and change them
  class TextDocumentManager
    @documents = Hash(DocumentUri, TextDocument).new

    # Open a text document
    def open(uri : DocumentUri, language_id : String, version : Int32, text : String)
      @documents[uri] = TextDocument.new(uri, language_id, version, text)
    end

    # Close a text document
    def close(uri : DocumentUri)
      @documents.delete(uri)
    end

    # Change a text document
    def change(uri : DocumentUri, version : Int32, changes : Array(TextDocumentContentChangeEvent))
      doc = @documents[uri]?
      return unless doc

      changes.each do |change|
        doc.apply_change(change)
      end
      doc.version = version
    end

    # Get a text document
    def get(uri : DocumentUri) : TextDocument?
      @documents[uri]?
    end

    # Get all text documents
    def all : Array(TextDocument)
      @documents.values
    end
  end

  # Represents a text document
  class TextDocument
    property uri : DocumentUri
    property language_id : String
    property version : Int32
    property text : String
    property lines : Array(String)

    # Initialize a text document
    def initialize(@uri : DocumentUri, @language_id : String, @version : Int32, @text : String)
      @lines = @text.split('\n')
    end

    # Apply a change to the text document
    def apply_change(change : TextDocumentContentChangeEvent)
      if range = change.range
        apply_incremental_change(range, change.text)
      else
        @text = change.text
        @lines = @text.split('\n')
      end
    end

    # Apply an incremental change to the text document
    private def apply_incremental_change(range : Range, new_text : String)
      start_line = range.start.line
      start_char = range.start.character
      end_line = range.end.line
      end_char = range.end.character
      before = ""
      if start_line > 0
        before = @lines[0...start_line].join('\n') + '\n'
      end
      before += @lines[start_line][0...start_char] if start_line < @lines.size

      after = ""
      if end_line < @lines.size
        after = @lines[end_line][end_char..-1] || ""
        if end_line < @lines.size - 1
          after += '\n' + @lines[(end_line + 1)..-1].join('\n')
        end
      end

      @text = before + new_text + after
      @lines = @text.split('\n')
    end

    # Get a line from the text document
    def get_line(line : Int32) : String?
      @lines[line]? if line >= 0 && line < @lines.size
    end

    # Get a word at a position in the text document
    def get_word_at_position(position : Position) : String?
      line = get_line(position.line)
      return nil unless line

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
      line[start_pos...end_pos]
    end

    private def word_char?(char : Char) : Bool
      char.alphanumeric? || char == '_' || char == '?' || char == '!'
    end

    # Get the offset at a position in the text document
    def offset_at(position : Position) : Int32
      offset = 0
      position.line.times do |i|
        offset += (@lines[i]?.try(&.size) || 0) + 1
      end
      offset + position.character
    end

    # Get the position at an offset in the text document
    def position_at(offset : Int32) : Position
      current_offset = 0
      @lines.each_with_index do |line, i|
        line_length = line.size + 1
        if current_offset + line_length > offset
          return Position.new(i, offset - current_offset)
        end
        current_offset += line_length
      end
      Position.new(@lines.size - 1, @lines.last?.try(&.size) || 0)
    end
  end

  # Text document content change event
  struct TextDocumentContentChangeEvent
    include JSON::Serializable

    property range : Range?
    property? range_length : Int32?
    property text : String

    def initialize(@text : String, @range : Range? = nil)
    end
  end

  # Text document position params
  struct TextDocumentPositionParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
    property position : Position
  end

  # Did open text document params
  struct DidOpenTextDocumentParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentItem
  end

  # Did change text document params
  struct DidChangeTextDocumentParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : VersionedTextDocumentIdentifier
    @[JSON::Field(key: "contentChanges")]
    property content_changes : Array(TextDocumentContentChangeEvent)
  end

  # Did close text document params
  struct DidCloseTextDocumentParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
  end

  # Did save text document params
  struct DidSaveTextDocumentParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
    property text : String?
  end

  # Publish diagnostics params
  struct PublishDiagnosticsParams
    include JSON::Serializable

    property uri : DocumentUri
    property diagnostics : Array(Diagnostic)

    def initialize(@uri : DocumentUri, @diagnostics : Array(Diagnostic))
    end
  end

  # Rename params
  struct RenameParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
    property position : Position
    @[JSON::Field(key: "newName")]
    property new_name : String
  end

  # Reference params
  struct ReferenceParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
    property position : Position
    property context : ReferenceContext
  end

  struct ReferenceContext
    include JSON::Serializable

    property? include_declaration : Bool
  end

  # Document symbol params
  struct DocumentSymbolParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
  end

  # Workspace symbol params
  struct WorkspaceSymbolParams
    include JSON::Serializable

    property query : String
  end

  # Completion params
  struct CompletionParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
    property position : Position
    property? context : CompletionContext?
  end

  struct CompletionContext
    include JSON::Serializable

    @[JSON::Field(key: "triggerKind")]
    property trigger_kind : Int32
    @[JSON::Field(key: "triggerCharacter")]
    property? trigger_character : String?
  end

  # Signature help params
  struct SignatureHelpParams
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
    property position : Position
  end
end
