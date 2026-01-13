require "compiler/crystal/syntax"
require "./lsp/protocol"
require "./lsp/json_rpc"
require "./lsp/text_document"
require "./lsp/server"
require "./crystal/parser"
require "./crystal/semantic_analyzer"

module Liger
  VERSION = "0.1.2"
end

def print_version
  puts "v#{Liger::VERSION}"
end

def print_help
  puts "Usage: liger [OPTIONS]"
  puts ""
  puts "OPTIONS:"
  puts "  --version    Show version information"
  puts "  --help       Show this help message"
  puts "  --strict     Enable stricter type checking"
end

if PROGRAM_NAME.includes?("liger")
  strict_mode = false

  if ARGV.includes?("--version") || ARGV.includes?("-v")
    print_version
    exit 0
  elsif ARGV.includes?("--help") || ARGV.includes?("-h")
    print_help
    exit 0
  elsif ARGV.includes?("--strict")
    strict_mode = true
    STDERR.puts "Strict type checking enabled"
  end

  begin
    server = LSP::Server.new
    server.enable_strict_mode if strict_mode
    server.run
  rescue exception
    STDERR.puts "Server crashed: #{exception.message}"
    STDERR.flush
  end
else
  STDERR.puts "Rename the executable to 'liger'."
end
