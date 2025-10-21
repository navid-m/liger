require "json"

module LSP
  alias DocumentUri = String
  alias ProgressToken = String | Int32

  # Position in a text document
  struct Position
    include JSON::Serializable

    property line : Int32
    property character : Int32

    def initialize(@line : Int32, @character : Int32)
    end

    def <=>(other : Position)
      line_cmp = @line <=> other.line
      return line_cmp unless line_cmp == 0
      @character <=> other.character
    end
  end

  # Range in a text document
  struct Range
    include JSON::Serializable

    property start : Position
    property end : Position

    def initialize(@start : Position, @end : Position)
    end

    def contains?(position : Position)
      position >= @start && position <= @end
    end
  end

  # Location in a text document
  struct Location
    include JSON::Serializable

    property uri : DocumentUri
    property range : Range

    def initialize(@uri : DocumentUri, @range : Range)
    end
  end

  # Diagnostic severity
  enum DiagnosticSeverity
    Error       = 1
    Warning     = 2
    Information = 3
    Hint        = 4
  end

  # Diagnostic message
  struct Diagnostic
    include JSON::Serializable

    property range : Range
    property severity : DiagnosticSeverity?
    property code : String | Int32 | Nil
    property source : String?
    property message : String
    property? tags : Array(Int32)?
    property? related_information : Array(DiagnosticRelatedInformation)?

    def initialize(@range : Range, @message : String, @severity : DiagnosticSeverity? = nil, @source : String? = nil)
    end
  end

  struct DiagnosticRelatedInformation
    include JSON::Serializable

    property location : Location
    property message : String
  end

  # Text edit
  struct TextEdit
    include JSON::Serializable

    property range : Range
    @[JSON::Field(key: "newText")]
    property new_text : String

    def initialize(@range : Range, @new_text : String)
    end
  end

  # Workspace edit
  struct WorkspaceEdit
    include JSON::Serializable

    property? changes : Hash(DocumentUri, Array(TextEdit))?
    property? document_changes : Array(TextDocumentEdit)?

    def initialize(@changes : Hash(DocumentUri, Array(TextEdit))? = nil)
    end
  end

  # Text document identifier
  struct TextDocumentIdentifier
    include JSON::Serializable

    property uri : DocumentUri

    def initialize(@uri : DocumentUri)
    end
  end

  # Versioned text document identifier
  struct VersionedTextDocumentIdentifier
    include JSON::Serializable

    property uri : DocumentUri
    property version : Int32

    def initialize(@uri : DocumentUri, @version : Int32)
    end
  end

  # Text document edit
  struct TextDocumentEdit
    include JSON::Serializable

    property text_document : VersionedTextDocumentIdentifier
    property edits : Array(TextEdit)
  end

  # Text document item
  struct TextDocumentItem
    include JSON::Serializable

    property uri : DocumentUri
    @[JSON::Field(key: "languageId")]
    property language_id : String
    property version : Int32
    property text : String

    def initialize(@uri : DocumentUri, @language_id : String, @version : Int32, @text : String)
    end
  end

  # Completion item kind
  enum CompletionItemKind
    Text          =  1
    Method        =  2
    Function      =  3
    Constructor   =  4
    Field         =  5
    Variable      =  6
    Class         =  7
    Interface     =  8
    Module        =  9
    Property      = 10
    Unit          = 11
    Value         = 12
    Enum          = 13
    Keyword       = 14
    Snippet       = 15
    Color         = 16
    File          = 17
    Reference     = 18
    Folder        = 19
    EnumMember    = 20
    Constant      = 21
    Struct        = 22
    Event         = 23
    Operator      = 24
    TypeParameter = 25
  end

  # Completion item
  struct CompletionItem
    include JSON::Serializable

    property label : String
    property kind : CompletionItemKind?
    property detail : String?
    property documentation : String?
    property? deprecated : Bool?
    property? preselect : Bool?
    @[JSON::Field(key: "sortText")]
    property sort_text : String?
    @[JSON::Field(key: "filterText")]
    property filter_text : String?
    @[JSON::Field(key: "insertText")]
    property insert_text : String?
    @[JSON::Field(key: "insertTextFormat")]
    property? insert_text_format : Int32?
    @[JSON::Field(key: "textEdit")]
    property? text_edit : TextEdit?
    @[JSON::Field(key: "additionalTextEdits")]
    property? additional_text_edits : Array(TextEdit)?
    @[JSON::Field(key: "commitCharacters")]
    property? commit_characters : Array(String)?
    property? data : JSON::Any?

    def initialize(@label : String, @kind : CompletionItemKind? = nil, @detail : String? = nil)
    end
  end

  # Completion list
  struct CompletionList
    include JSON::Serializable

    property? is_incomplete : Bool
    property items : Array(CompletionItem)

    def initialize(@items : Array(CompletionItem), @is_incomplete : Bool = false)
    end
  end

  # Symbol kind
  enum SymbolKind
    File          =  1
    Module        =  2
    Namespace     =  3
    Package       =  4
    Class         =  5
    Method        =  6
    Property      =  7
    Field         =  8
    Constructor   =  9
    Enum          = 10
    Interface     = 11
    Function      = 12
    Variable      = 13
    Constant      = 14
    String        = 15
    Number        = 16
    Boolean       = 17
    Array         = 18
    Object        = 19
    Key           = 20
    Null          = 21
    EnumMember    = 22
    Struct        = 23
    Event         = 24
    Operator      = 25
    TypeParameter = 26
  end

  # Document symbol
  struct DocumentSymbol
    include JSON::Serializable

    property name : String
    property detail : String?
    property kind : SymbolKind
    property? deprecated : Bool?
    property range : Range
    @[JSON::Field(key: "selectionRange")]
    property selection_range : Range
    property? children : Array(DocumentSymbol)?

    def initialize(@name : String, @kind : SymbolKind, @range : Range, @selection_range : Range)
    end
  end

  # Symbol information
  struct SymbolInformation
    include JSON::Serializable

    property name : String
    property kind : SymbolKind
    property? deprecated : Bool?
    property location : Location
    @[JSON::Field(key: "containerName")]
    property? container_name : String?

    def initialize(@name : String, @kind : SymbolKind, @location : Location)
    end
  end

  # Markup content
  struct MarkupContent
    include JSON::Serializable

    property kind : String
    property value : String

    def initialize(@kind : String, @value : String)
    end
  end

  # Hover result
  struct Hover
    include JSON::Serializable

    property contents : MarkupContent | String
    property range : Range?

    def initialize(@contents : MarkupContent | String, @range : Range? = nil)
    end
  end

  # Signature information
  struct SignatureInformation
    include JSON::Serializable

    property label : String
    property documentation : String | MarkupContent | Nil
    property? parameters : Array(ParameterInformation)?

    def initialize(@label : String)
    end
  end

  # Parameter information
  struct ParameterInformation
    include JSON::Serializable

    property label : String | Array(Int32)
    property documentation : String | MarkupContent | Nil

    def initialize(@label : String | Array(Int32))
    end
  end

  # Signature help
  struct SignatureHelp
    include JSON::Serializable

    property signatures : Array(SignatureInformation)
    property? active_signature : Int32?
    property? active_parameter : Int32?

    def initialize(@signatures : Array(SignatureInformation))
    end
  end

  # Server capabilities
  struct ServerCapabilities
    include JSON::Serializable

    property? text_document_sync : Int32?
    property? hover_provider : Bool?
    property? completion_provider : CompletionOptions?
    property? signature_help_provider : SignatureHelpOptions?
    property? definition_provider : Bool?
    property? references_provider : Bool?
    property? document_highlight_provider : Bool?
    property? document_symbol_provider : Bool?
    property? workspace_symbol_provider : Bool?
    property? code_action_provider : Bool?
    property? code_lens_provider : CodeLensOptions?
    property? document_formatting_provider : Bool?
    property? document_range_formatting_provider : Bool?
    property? rename_provider : Bool | RenameOptions?
    property? document_link_provider : DocumentLinkOptions?
    property? execute_command_provider : ExecuteCommandOptions?
    property? workspace : WorkspaceServerCapabilities?

    def initialize
    end
  end

  struct CompletionOptions
    include JSON::Serializable

    property? resolve_provider : Bool?
    property? trigger_characters : Array(String)?

    def initialize(@trigger_characters : Array(String)? = nil, @resolve_provider : Bool? = nil)
    end
  end

  struct SignatureHelpOptions
    include JSON::Serializable

    property? trigger_characters : Array(String)?
    property? retrigger_characters : Array(String)?

    def initialize(@trigger_characters : Array(String)? = nil)
    end
  end

  struct CodeLensOptions
    include JSON::Serializable

    property? resolve_provider : Bool?
  end

  struct RenameOptions
    include JSON::Serializable

    property? prepare_provider : Bool?

    def initialize(@prepare_provider : Bool? = nil)
    end
  end

  struct DocumentLinkOptions
    include JSON::Serializable

    property? resolve_provider : Bool?
  end

  struct ExecuteCommandOptions
    include JSON::Serializable

    property commands : Array(String)

    def initialize(@commands : Array(String))
    end
  end

  struct WorkspaceServerCapabilities
    include JSON::Serializable

    property? workspace_folders : WorkspaceFoldersServerCapabilities?
  end

  struct WorkspaceFoldersServerCapabilities
    include JSON::Serializable

    property? supported : Bool?
    property? change_notifications : Bool | String?
  end
end
