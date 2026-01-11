require "json"
require "./protocol"
require "./json_rpc"
require "./text_document"
require "../crystal/parser"
require "../crystal/semantic_analyzer"

module LSP
  # LSP server implementation
  class Server
    @rpc : JsonRpcHandler
    @document_manager : TextDocumentManager
    @semantic_analyzer : Liger::SemanticAnalyzer
    @initialized = false
    @workspace_root : String?
    @shutdown_requested = false

    # Initialize the server
    def initialize(input : IO = STDIN, output : IO = STDOUT)
      @rpc = JsonRpcHandler.new(input, output)
      @document_manager = TextDocumentManager.new
      @semantic_analyzer = Liger::SemanticAnalyzer.new

      setup_handlers
    end

    # Run the server
    def run
      STDERR.puts "Liger LSP server starting..."
      @rpc.listen
    end

    # Setup request and notification handlers
    private def setup_handlers
      @rpc.on_request("initialize") { |params| handle_initialize(params) }
      @rpc.on_notification("initialized") { |params| handle_initialized(params) }
      @rpc.on_request("shutdown") { |params| handle_shutdown(params) }
      @rpc.on_notification("exit") { |params| handle_exit(params) }
      @rpc.on_notification("textDocument/didOpen") { |params| handle_did_open(params) }
      @rpc.on_notification("textDocument/didChange") { |params| handle_did_change(params) }
      @rpc.on_notification("textDocument/didClose") { |params| handle_did_close(params) }
      @rpc.on_notification("textDocument/didSave") { |params| handle_did_save(params) }
      @rpc.on_request("textDocument/completion") { |params| handle_completion(params) }
      @rpc.on_request("textDocument/hover") { |params| handle_hover(params) }
      @rpc.on_request("textDocument/signatureHelp") { |params| handle_signature_help(params) }
      @rpc.on_request("textDocument/definition") { |params| handle_definition(params) }
      @rpc.on_request("textDocument/references") { |params| handle_references(params) }
      @rpc.on_request("textDocument/documentSymbol") { |params| handle_document_symbol(params) }
      @rpc.on_request("workspace/symbol") { |params| handle_workspace_symbol(params) }
      @rpc.on_request("textDocument/rename") { |params| handle_rename(params) }
      @rpc.on_request("textDocument/prepareRename") { |params| handle_prepare_rename(params) }
    end

    # Handle an initialize request
    private def handle_initialize(params : JSON::Any?) : JSON::Any
      STDERR.puts "Handling initialize request"

      if params
        root_uri = params["rootUri"]?.try(&.as_s?)
        @workspace_root = root_uri
        @semantic_analyzer.workspace_root = root_uri
      end

      capabilities = {
        "textDocumentSync"   => 1,
        "hoverProvider"      => true,
        "completionProvider" => {
          "triggerCharacters" => [".", ":", "@"],
          "resolveProvider"   => false,
        },
        "signatureHelpProvider" => {
          "triggerCharacters" => ["(", ","],
        },
        "definitionProvider"      => true,
        "referencesProvider"      => true,
        "documentSymbolProvider"  => true,
        "workspaceSymbolProvider" => true,
        "renameProvider"          => {
          "prepareProvider" => true,
        },
      }

      result = {
        "capabilities" => capabilities,
        "serverInfo"   => {
          "name"    => "Liger",
          "version" => Liger::VERSION,
        },
      }

      @initialized = true
      JSON.parse(result.to_json)
    end

    # Handle an initialized notification
    private def handle_initialized(params : JSON::Any?)
      STDERR.puts "Server initialized"
    end

    # Handle a shutdown request
    private def handle_shutdown(params : JSON::Any?) : JSON::Any
      STDERR.puts "Shutdown requested"
      @shutdown_requested = true
      JSON.parse("null")
    end

    # Handle an exit notification
    private def handle_exit(params : JSON::Any?)
      STDERR.puts "Exiting"
      exit(0)
    end

    # Handle a didOpen notification
    private def handle_did_open(params : JSON::Any?)
      return unless params

      did_open = DidOpenTextDocumentParams.from_json(params.to_json)
      doc = did_open.text_document

      @document_manager.open(doc.uri, doc.language_id, doc.version, doc.text)
      @semantic_analyzer.update_source(doc.uri, doc.text)

      send_diagnostics(doc.uri)
    end

    # Handle a didChange notification
    private def handle_did_change(params : JSON::Any?)
      return unless params

      did_change = DidChangeTextDocumentParams.from_json(params.to_json)
      doc = did_change.text_document

      @document_manager.change(doc.uri, doc.version, did_change.content_changes)

      if text_doc = @document_manager.get(doc.uri)
        @semantic_analyzer.update_source(doc.uri, text_doc.text)
      end

      send_diagnostics(doc.uri)
    end

    # Handle a didClose notification
    private def handle_did_close(params : JSON::Any?)
      return unless params

      did_close = DidCloseTextDocumentParams.from_json(params.to_json)
      @document_manager.close(did_close.text_document.uri)
      @semantic_analyzer.remove_source(did_close.text_document.uri)
    end

    # Handle a didSave notification
    private def handle_did_save(params : JSON::Any?)
      return unless params

      did_save = DidSaveTextDocumentParams.from_json(params.to_json)
      send_diagnostics(did_save.text_document.uri)
    end

    # Completion request
    private def handle_completion(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      completion_params = CompletionParams.from_json(params.to_json)
      doc = @document_manager.get(completion_params.text_document.uri)
      return JSON.parse("null") unless doc

      items = [] of LSP::CompletionItem

      parser = Liger::CrystalParser.new(doc.uri, doc.text)
      items += parser.completions(completion_params.position)

      semantic_items = @semantic_analyzer.completions(doc.uri, completion_params.position)
      items += semantic_items

      items = items.uniq { |item| item.label }

      json_response = items.to_json

      JSON.parse(json_response)
    end

    # Hover request
    private def handle_hover(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      hover_params = TextDocumentPositionParams.from_json(params.to_json)
      doc = @document_manager.get(hover_params.text_document.uri)
      return JSON.parse("null") unless doc

      if hover = @semantic_analyzer.hover(doc.uri, hover_params.position)
        return JSON.parse(hover.to_json)
      end
      if word = doc.get_word_at_position(hover_params.position)
        content = MarkupContent.new("markdown", "**#{word}**")
        hover = Hover.new(content)
        return JSON.parse(hover.to_json)
      end

      JSON.parse("null")
    end

    # Signature help request
    private def handle_signature_help(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      sig_params = SignatureHelpParams.from_json(params.to_json)
      doc = @document_manager.get(sig_params.text_document.uri)
      return JSON.parse("null") unless doc

      if sig_help = @semantic_analyzer.signature_help(doc.uri, sig_params.position)
        return JSON.parse(sig_help.to_json)
      end

      JSON.parse("null")
    end

    # Definition request
    private def handle_definition(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      def_params = TextDocumentPositionParams.from_json(params.to_json)
      doc = @document_manager.get(def_params.text_document.uri)
      return JSON.parse("null") unless doc

      if location = @semantic_analyzer.find_definition(doc.uri, def_params.position)
        json_result = location.to_json
        File.write("/tmp/liger_logs.log", "Returning location JSON: #{json_result}\n", mode: "a")
        return JSON.parse(json_result)
      end

      JSON.parse("null")
    end

    # References request
    private def handle_references(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      ref_params = ReferenceParams.from_json(params.to_json)
      doc = @document_manager.get(ref_params.text_document.uri)
      return JSON.parse("null") unless doc

      locations = @semantic_analyzer.find_references(
        doc.uri,
        ref_params.position,
        ref_params.context.include_declaration? || false
      )

      JSON.parse(locations.to_json)
    end

    # Document symbol request
    private def handle_document_symbol(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      symbol_params = DocumentSymbolParams.from_json(params.to_json)
      doc = @document_manager.get(symbol_params.text_document.uri)
      return JSON.parse("null") unless doc

      parser = Liger::CrystalParser.new(doc.uri, doc.text)
      doc_symbols = parser.document_symbols

      symbol_infos = [] of SymbolInformation
      flatten_document_symbols(doc_symbols, doc.uri, symbol_infos)

      JSON.parse(symbol_infos.to_json)
    end

    # Flatten hierarchical DocumentSymbol to flat SymbolInformation
    private def flatten_document_symbols(
      symbols : Array(DocumentSymbol),
      uri : String,
      result : Array(SymbolInformation),
      container : String? = nil,
    )
      symbols.each do |sym|
        location = Location.new(uri, sym.selection_range)
        info = SymbolInformation.new(sym.name, sym.kind, location)
        info.container_name = container if container
        result << info

        if children = sym.children?
          flatten_document_symbols(children, uri, result, sym.name)
        end
      end
    end

    # Workspace symbol request
    private def handle_workspace_symbol(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      symbol_params = WorkspaceSymbolParams.from_json(params.to_json)
      query = symbol_params.query.downcase

      symbols = [] of SymbolInformation

      @document_manager.all.each do |doc|
        parser = Liger::CrystalParser.new(doc.uri, doc.text)
        doc_symbols = parser.document_symbols
        doc_symbols.each do |sym|
          if sym.name.downcase.includes?(query)
            location = Location.new(doc.uri, sym.range)
            symbols << SymbolInformation.new(sym.name, sym.kind, location)
          end
        end
      end

      JSON.parse(symbols.to_json)
    end

    # Prepare rename request
    private def handle_prepare_rename(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      rename_params = TextDocumentPositionParams.from_json(params.to_json)
      doc = @document_manager.get(rename_params.text_document.uri)
      return JSON.parse("null") unless doc

      if range = @semantic_analyzer.prepare_rename(doc.uri, rename_params.position)
        return JSON.parse(range.to_json)
      end
      if word = doc.get_word_at_position(rename_params.position)
        line = doc.get_line(rename_params.position.line)
        return JSON.parse("null") unless line
        char = rename_params.position.character
        start_pos = char
        while start_pos > 0 && word_char?(line[start_pos - 1])
          start_pos -= 1
        end

        end_pos = char
        while end_pos < line.size && word_char?(line[end_pos])
          end_pos += 1
        end

        range = Range.new(
          Position.new(rename_params.position.line, start_pos),
          Position.new(rename_params.position.line, end_pos)
        )
        return JSON.parse(range.to_json)
      end

      JSON.parse("null")
    end

    # Rename request
    private def handle_rename(params : JSON::Any?) : JSON::Any
      return JSON.parse("null") unless params

      rename_params = RenameParams.from_json(params.to_json)
      doc = @document_manager.get(rename_params.text_document.uri)
      return JSON.parse("null") unless doc

      if edit = @semantic_analyzer.rename(doc.uri, rename_params.position, rename_params.new_name)
        return JSON.parse(edit.to_json)
      end

      JSON.parse("null")
    end

    # Send diagnostics for a document
    private def send_diagnostics(uri : DocumentUri)
      doc = @document_manager.get(uri)
      return unless doc

      diagnostics = @semantic_analyzer.analyze(uri)
      publish_params = PublishDiagnosticsParams.new(uri, diagnostics)
      @rpc.send_notification("textDocument/publishDiagnostics", JSON.parse(publish_params.to_json))
    end

    # Check if a character is a word character
    private def word_char?(char : Char) : Bool
      char.alphanumeric? || char == '_' || char == '?' || char == '!'
    end
  end
end
