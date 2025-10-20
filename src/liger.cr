require "compiler/crystal/syntax"
require "./lsp/protocol"
require "./lsp/json_rpc"
require "./lsp/text_document"
require "./lsp/server"
require "./crystal/parser"
require "./crystal/semantic_analyzer"

module Liger
  VERSION = "0.1.0"
end

# Start the LSP server
server = LSP::Server.new
server.run
