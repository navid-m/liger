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

def print_version
  puts "Liger #{Liger::VERSION}"
end

def print_help
  puts "Usage: liger [OPTIONS]"
  puts ""
  puts "OPTIONS:"
  puts "  --version    Show version information"
  puts "  --help       Show this help message"
end

if ARGV.includes?("--version")
  print_version
  exit 0
elsif ARGV.includes?("--help")
  print_help
  exit 0
end

begin
  server = LSP::Server.new
  server.run
rescue exception
  STDERR.puts "Server crashed: #{exception.message}"
  STDERR.flush
end
