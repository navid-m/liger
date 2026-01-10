require "../lsp/protocol"
require "file_utils"

module Liger
  class WorkspaceAnalyzer
    @workspace_root : String?
    @file_cache = Hash(String, String).new
    @symbol_cache = Hash(String, Array(SymbolInfo)).new
    @last_scan_time : Time?

    struct SymbolInfo
      property name : String
      property type : String
      property kind : String
      property file : String
      property line : Int32
      property signature : String?
      property documentation : String?

      def initialize(@name : String, @type : String, @kind : String, @file : String, @line : Int32, @signature : String? = nil, @documentation : String? = nil)
      end
    end

    def initialize(@workspace_root : String? = nil)
    end

    def update_source(uri : String, source : String)
      @last_scan_time = nil

      filename = uri_to_filename(uri)
      if filename.ends_with?(".cr")
        temp_content = @file_cache[filename]?
        @file_cache[filename] = source
        scan_file_content(filename, source)
      end
    end

    def force_scan
      @last_scan_time = nil
      scan_workspace_if_needed
    end

    def find_symbol_info(symbol_name : String) : SymbolInfo?
      scan_workspace_if_needed

      STDERR.puts "Looking for symbol: '#{symbol_name}'"
      STDERR.puts "Symbol cache has #{@symbol_cache.size} files with #{@symbol_cache.values.sum(&.size)} total symbols"

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name == symbol_name
            STDERR.puts "Found exact match: #{symbol.name} (#{symbol.kind}) in #{symbol.file}:#{symbol.line}"
            return symbol
          end
        end
      end

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name.ends_with?("::#{symbol_name}") || symbol.name.ends_with?(symbol_name)
            STDERR.puts "Found partial match: #{symbol.name} (#{symbol.kind}) in #{symbol.file}:#{symbol.line}"
            return symbol
          end
        end
      end

      STDERR.puts "No symbol found for: '#{symbol_name}'"
      nil
    end

    def find_method_info(receiver_type : String, method_name : String) : SymbolInfo?
      scan_workspace_if_needed

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.kind == "method" && symbol.name == method_name
            if symbol.type.includes?(receiver_type) || receiver_type.includes?(symbol.type)
              return symbol
            end
          end
        end
      end

      nil
    end

    def get_type_at_position(uri : String, source : String, position : LSP::Position) : String?
      lines = source.split('\n')
      return nil if position.line >= lines.size

      line = lines[position.line]
      word = extract_word_at_position(line, position.character)
      return nil unless word

      if word.starts_with?("@")
        if type = find_instance_variable_type(source, word)
          return type
        end
        if symbol = find_symbol_info(word)
          return symbol.type
        end
      end

      if dot_pos = find_dot_before_position(line, position.character)
        receiver_word = extract_word_before_position(line, dot_pos)
        if receiver_word
          receiver_type = get_receiver_type(source, receiver_word, position.line)
          if receiver_type
            return get_method_return_type(receiver_type, word)
          end
        end
      end

      if type = find_variable_type(source, word, position.line)
        return type
      end

      if type = find_method_return_type(source, word)
        return type
      end

      if symbol = find_symbol_info(word)
        return symbol.type
      end

      nil
    end

    private def scan_workspace_if_needed
      return unless @workspace_root
      return if @last_scan_time && (Time.utc - @last_scan_time.not_nil!).total_seconds < 5

      workspace_path = uri_to_filename(@workspace_root.not_nil!)
      return unless Dir.exists?(workspace_path)

      STDERR.puts "Scanning workspace: #{workspace_path}"
      @symbol_cache.clear
      scan_directory(workspace_path)
      @last_scan_time = Time.utc
      STDERR.puts "Workspace scan complete. Found #{@symbol_cache.values.sum(&.size)} symbols"
    end

    private def scan_directory(path : String)
      Dir.each_child(path) do |entry|
        full_path = File.join(path, entry)

        if Dir.exists?(full_path)
          next if entry.starts_with?('.') || entry == "lib" || entry == "bin"
          scan_directory(full_path)
        elsif entry.ends_with?(".cr")
          scan_file(full_path)
        end
      end
    end

    private def extract_documentation(lines : Array(String), line_num : Int32) : String?
      docs = [] of String
      current_line = line_num - 1

      while current_line >= 0
        line = lines[current_line].strip
        if line.starts_with?("#")
          docs.unshift(line.sub(/^#\s?/, ""))
          current_line -= 1
        elsif line.empty?
          current_line -= 1
        else
          break
        end
      end

      docs.empty? ? nil : docs.join("\n")
    end

    private def scan_file_content(file_path : String, content : String)
      @file_cache[file_path] = content

      symbols = [] of SymbolInfo
      lines = content.split('\n')
      current_namespace = [] of String

      lines.each_with_index do |line, line_num|
        # Track current class/module context
        if match = line.match(/^\s*class\s+(\w+)(?:\s*<\s*(\w+))?/)
          class_name = match[1]
          parent_class = match[2]? || "Object"
          full_name = (current_namespace + [class_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(class_name, parent_class, "class", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, parent_class, "class", file_path, line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(class_name)
        elsif match = line.match(/^\s*module\s+(\w+)/)
          module_name = match[1]
          full_name = (current_namespace + [module_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(module_name, "Module", "module", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, "Module", "module", file_path, line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(module_name)
        elsif line.match(/^\s*end\s*$/)
          current_namespace.pop if current_namespace.any?
        end

        scan_line_for_symbols(line, line_num, file_path, current_namespace, symbols, lines)
      end

      @symbol_cache[file_path] = symbols
    end

    private def scan_line_for_symbols(line : String, line_num : Int32, file_path : String, current_namespace : Array(String), symbols : Array(SymbolInfo), lines : Array(String))
      # Enum definitions
      if match = line.match(/^\s*enum\s+(\w+)/)
        enum_name = match[1]
        full_name = (current_namespace + [enum_name]).join("::")
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(enum_name, "Enum", "enum", file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(full_name, "Enum", "enum", file_path, line_num, line.strip, doc) if current_namespace.any?
      end

      # Struct definitions
      if match = line.match(/^\s*struct\s+(\w+)/)
        struct_name = match[1]
        full_name = (current_namespace + [struct_name]).join("::")
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(struct_name, "Struct", "struct", file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(full_name, "Struct", "struct", file_path, line_num, line.strip, doc) if current_namespace.any?
      end

      # Method definitions
      if match = line.match(/^\s*(?:private\s+)?def\s+(\w+)(?:\([^)]*\))?\s*:\s*(\w+)/)
        method_name = match[1]
        return_type = match[2]
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(method_name, return_type, "method", file_path, line_num, line.strip, doc)
      elsif match = line.match(/^\s*(?:private\s+)?def\s+(\w+)(?:\([^)]*\))?/)
        method_name = match[1]
        return_type = "Object"
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(method_name, return_type, "method", file_path, line_num, line.strip, doc)
      end

      # Property declarations
      if match = line.match(/^\s*(?:property|getter|setter)\s+(\w+)\s*:\s*(\w+)/)
        prop_name = "@#{match[1]}"
        prop_type = match[2]
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(prop_name, prop_type, "property", file_path, line_num, line.strip, doc)
      end

      # Instance variables
      if match = line.match(/^\s*@(\w+)\s*:\s*(\w+)/)
        var_name = "@#{match[1]}"
        var_type = match[2]
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(var_name, var_type, "instance_variable", file_path, line_num, line.strip, doc)
      end

      # Constants
      if match = line.match(/^\s*([A-Z][A-Z_]*)\s*=\s*(.+)/)
        const_name = match[1]
        const_value = match[2].strip
        const_type = infer_type_from_value(const_value)
        full_name = (current_namespace + [const_name]).join("::")
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(const_name, const_type, "constant", file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(full_name, const_type, "constant", file_path, line_num, line.strip, doc) if current_namespace.any?
      end
    end

    private def scan_file(file_path : String)
      return unless File.exists?(file_path)

      content = File.read(file_path)
      @file_cache[file_path] = content

      symbols = [] of SymbolInfo
      lines = content.split('\n')
      current_class = nil
      current_module = nil
      current_namespace = [] of String

      lines.each_with_index do |line, line_num|
        if match = line.match(/^\s*class\s+(\w+)(?:\s*<\s*(\w+))?/)
          current_class = match[1]
          parent_class = match[2]? || "Object"
          full_name = (current_namespace + [current_class]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(current_class, parent_class, "class", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, parent_class, "class", file_path, line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(current_class)
        elsif match = line.match(/^\s*module\s+(\w+)/)
          current_module = match[1]
          full_name = (current_namespace + [current_module]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(current_module, "Module", "module", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, "Module", "module", file_path, line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(current_module)
        elsif line.match(/^\s*end\s*$/)
          if current_namespace.any?
            popped = current_namespace.pop
            if popped == current_class
              current_class = nil
            elsif popped == current_module
              current_module = nil
            end
          end
        end

        # Enum definitions
        if match = line.match(/^\s*enum\s+(\w+)/)
          enum_name = match[1]
          full_name = (current_namespace + [enum_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(enum_name, "Enum", "enum", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, "Enum", "enum", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Struct definitions
        if match = line.match(/^\s*struct\s+(\w+)/)
          struct_name = match[1]
          full_name = (current_namespace + [struct_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(struct_name, "Struct", "struct", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, "Struct", "struct", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Alias definitions
        if match = line.match(/^\s*alias\s+(\w+)\s*=\s*(.+)/)
          alias_name = match[1]
          alias_type = match[2].strip
          full_name = (current_namespace + [alias_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(alias_name, alias_type, "alias", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, alias_type, "alias", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Constants
        if match = line.match(/^\s*([A-Z][A-Z_]*)\s*=\s*(.+)/)
          const_name = match[1]
          const_value = match[2].strip
          const_type = infer_type_from_value(const_value)
          full_name = (current_namespace + [const_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(const_name, const_type, "constant", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_name, const_type, "constant", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Property declarations (property, getter, setter)
        if match = line.match(/^\s*property\s+(\w+)\s*:\s*(\w+)/)
          prop_name = "@#{match[1]}"
          prop_type = match[2]
          containing_type = current_namespace.join("::") || "Object"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(prop_name, prop_type, "property", file_path, line_num, line.strip, doc)
        elsif match = line.match(/^\s*getter\s+(\w+)\s*:\s*(\w+)/)
          prop_name = "@#{match[1]}"
          prop_type = match[2]
          containing_type = current_namespace.join("::") || "Object"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(prop_name, prop_type, "getter", file_path, line_num, line.strip, doc)
        elsif match = line.match(/^\s*setter\s+(\w+)\s*:\s*(\w+)/)
          prop_name = "@#{match[1]}"
          prop_type = match[2]
          containing_type = current_namespace.join("::") || "Object"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(prop_name, prop_type, "setter", file_path, line_num, line.strip, doc)
        end

        # Method definitions with return types
        if match = line.match(/^\s*def\s+(\w+)(?:\([^)]*\))?\s*:\s*(\w+)/)
          method_name = match[1]
          return_type = match[2]
          containing_type = current_namespace.join("::") || "Object"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(method_name, return_type, "method", file_path, line_num, line.strip, doc)
        elsif match = line.match(/^\s*def\s+(\w+)(?:\([^)]*\))?/)
          method_name = match[1]
          # Try to infer return type from method body
          return_type = infer_method_return_type(lines, line_num)
          containing_type = current_namespace.join("::") || "Object"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(method_name, return_type, "method", file_path, line_num, line.strip, doc)
        end

        # Private method definitions
        if match = line.match(/^\s*private\s+def\s+(\w+)(?:\([^)]*\))?\s*:\s*(\w+)/)
          method_name = match[1]
          return_type = match[2]
          containing_type = current_namespace.join("::") || "Object"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(method_name, return_type, "method", file_path, line_num, line.strip, doc)
        elsif match = line.match(/^\s*private\s+def\s+(\w+)(?:\([^)]*\))?/)
          method_name = match[1]
          return_type = infer_method_return_type(lines, line_num)
          containing_type = current_namespace.join("::") || "Object"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(method_name, return_type, "method", file_path, line_num, line.strip, doc)
        end

        # Variable assignments with explicit types
        if match = line.match(/^\s*(\w+)\s*:\s*(\w+)\s*=/)
          var_name = match[1]
          var_type = match[2]
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(var_name, var_type, "variable", file_path, line_num, line.strip, doc)
        end

        # Instance variable assignments
        if match = line.match(/^\s*@(\w+)\s*:\s*(\w+)/)
          var_name = "@#{match[1]}"
          var_type = match[2]
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(var_name, var_type, "instance_variable", file_path, line_num, line.strip, doc)
        end
      end

      @symbol_cache[file_path] = symbols
    end

    private def find_variable_type(source : String, var_name : String, current_line : Int32) : String?
      lines = source.split('\n')

      (0...current_line).reverse_each do |line_num|
        line = lines[line_num]

        if match = line.match(/#{Regex.escape(var_name)}\s*:\s*(\w+)\s*=/)
          return match[1]
        end

        if match = line.match(/#{Regex.escape(var_name)}\s*=\s*(.+)/)
          assignment = match[1].strip
          return infer_type_from_value(assignment)
        end
      end

      nil
    end

    private def find_method_return_type(source : String, method_name : String) : String?
      lines = source.split('\n')

      lines.each_with_index do |line, line_num|
        if match = line.match(/def\s+#{Regex.escape(method_name)}(?:\([^)]*\))?\s*:\s*(\w+)/)
          return match[1]
        elsif match = line.match(/def\s+#{Regex.escape(method_name)}(?:\([^)]*\))?/)
          return infer_method_return_type(lines, line_num)
        end
      end

      nil
    end

    private def infer_method_return_type(lines : Array(String), method_start : Int32) : String
      (method_start + 1...lines.size).each do |i|
        line = lines[i]
        break if line.match(/^\s*end\s*$/)

        if match = line.match(/return\s+(.+)/)
          return infer_type_from_value(match[1].strip)
        end
      end

      (method_start + 1...lines.size).each do |i|
        line = lines[i]
        if line.match(/^\s*end\s*$/)
          if i > method_start + 1
            last_line = lines[i - 1].strip
            return infer_type_from_value(last_line) unless last_line.empty?
          end
          break
        end
      end

      "Object"
    end

    private def infer_type_from_value(value : String) : String
      value = value.strip

      return "String" if value.starts_with?('"') || value.starts_with?("'")
      return "Int32" if value.match(/^\d+$/)
      return "Int64" if value.match(/^\d+_i64$/) || value.match(/^\d+i64$/)
      return "Float64" if value.match(/^\d+\.\d+$/)
      return "Float32" if value.match(/^\d+\.\d+_f32$/) || value.match(/^\d+\.\d+f32$/)
      return "Bool" if value == "true" || value == "false"
      return "Nil" if value == "nil"
      return "Array" if value.starts_with?('[')
      return "Hash" if value.starts_with?('{')
      return "Regex" if value.starts_with?('/')
      return "Symbol" if value.starts_with?(':')
      return "Char" if value.match(/^'.'$/)
      return "Range" if value.includes?("..")

      if match = value.match(/(\w+)\.(\w+)/)
        receiver = match[1]
        method = match[2]

        case method
        when "to_s"           then return "String"
        when "to_i"           then return "Int32"
        when "to_f"           then return "Float64"
        when "size", "length" then return "Int32"
        when "empty?"         then return "Bool"
        when "split"          then return "Array(String)"
        when "chars"          then return "Array(Char)"
        when "keys"           then return "Array"
        when "values"         then return "Array"
        when "first", "last"  then return "T"
        end
      end

      # Constructor calls
      if match = value.match(/(\w+)\.new/)
        return match[1]
      end

      # Array/Hash literals with type annotation
      if match = value.match(/Array\((\w+)\)\.new/)
        return "Array(#{match[1]})"
      elsif match = value.match(/\[\]\s*of\s+(\w+)/)
        return "Array(#{match[1]})"
      end

      if match = value.match(/Hash\((\w+),\s*(\w+)\)\.new/)
        return "Hash(#{match[1]}, #{match[2]})"
      elsif match = value.match(/\{\}\s*of\s+(\w+)\s*=>\s*(\w+)/)
        return "Hash(#{match[1]}, #{match[2]})"
      end

      # Class instantiation
      if match = value.match(/^(\w+)\.new/)
        return match[1]
      end

      "Object"
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

    private def word_char?(char : Char) : Bool
      char.alphanumeric? || char == '_' || char == '?' || char == '!' || char == '@'
    end

    def get_completions_for_receiver(receiver_type : String) : Array(String)
      completions = [] of String

      case receiver_type
      when "String"
        completions = ["size", "empty?", "upcase", "downcase", "strip", "split", "starts_with?", "ends_with?", "includes?", "chars", "gsub", "match", "to_i", "to_f", "reverse", "capitalize", "chomp", "lstrip", "rstrip"]
      when "Array"
        completions = ["each", "map", "select", "reject", "first", "last", "push", "pop", "sort", "size", "empty?", "join", "reverse", "uniq", "flatten", "compact", "insert", "delete", "clear"]
      when "Hash"
        completions = ["each", "keys", "values", "has_key?", "size", "empty?", "merge", "delete", "clear", "fetch", "dig", "transform_keys", "transform_values"]
      when "Int32", "Int64"
        completions = ["to_s", "to_f", "abs", "even?", "odd?", "succ", "pred", "times", "upto", "downto", "step"]
      when "Float64", "Float32"
        completions = ["to_s", "to_i", "round", "ceil", "floor", "abs", "finite?", "infinite?", "nan?"]
      when "Bool"
        completions = ["to_s", "hash"]
      when "Range"
        completions = ["each", "map", "select", "first", "last", "size", "empty?", "includes?", "covers?"]
      when "Regex"
        completions = ["match", "scan", "split", "gsub", "source", "options"]
      when "Symbol"
        completions = ["to_s", "hash", "inspect"]
      when "Char"
        completions = ["to_s", "ord", "upcase", "downcase", "ascii?", "alphanumeric?", "whitespace?"]
      when "Time"
        completions = ["year", "month", "day", "hour", "minute", "second", "to_s", "to_unix", "utc", "local"]
      when "File"
        completions = ["read", "write", "close", "flush", "size", "path", "closed?"]
      when "IO"
        completions = ["read", "write", "close", "flush", "closed?", "gets", "puts", "print"]
      else
        @symbol_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.kind == "method" && (symbol.type.includes?(receiver_type) || receiver_type.includes?(symbol.type))
              completions << symbol.name
            end
          end
        end
        completions += ["to_s", "inspect", "class", "nil?", "is_a?", "responds_to?", "hash", "dup", "clone"]
      end

      completions.uniq
    end

    def find_property_definition(
      property_name : String,
      current_uri : String,
      current_source : String,
    ) : SymbolInfo?
      if symbol = find_property_in_source(current_source, property_name, current_uri)
        return symbol
      end

      scan_workspace_if_needed
      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if (symbol.kind == "property" || symbol.kind == "getter" || symbol.kind == "setter" || symbol.kind == "instance_variable") && symbol.name == property_name
            return symbol
          end
        end
      end

      nil
    end

    def find_method_definition(receiver_type : String, method_name : String) : SymbolInfo?
      scan_workspace_if_needed

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.kind == "method" && symbol.name == method_name
            # Check if this method belongs to the receiver type or its hierarchy
            if symbol.type.includes?(receiver_type) || receiver_type.includes?(symbol.type) ||
               is_method_available_for_type(symbol, receiver_type)
              return symbol
            end
          end
        end
      end

      nil
    end

    private def find_property_in_source(source : String, property_name : String, uri : String) : SymbolInfo?
      lines = source.split('\n')
      clean_name = property_name.sub("@", "")

      lines.each_with_index do |line, line_num|
        # property name : Type
        if match = line.match(/property\s+#{Regex.escape(clean_name)}\s*:\s*(\w+)/)
          doc = extract_documentation(lines, line_num)
          return SymbolInfo.new(
            property_name, match[1], "property", uri_to_filename(uri), line_num, line.strip, doc)
        end
        # getter name : Type
        if match = line.match(/getter\s+#{Regex.escape(clean_name)}\s*:\s*(\w+)/)
          doc = extract_documentation(lines, line_num)
          return SymbolInfo.new(
            property_name, match[1], "getter", uri_to_filename(uri), line_num, line.strip, doc)
        end
        # setter name : Type
        if match = line.match(/setter\s+#{Regex.escape(clean_name)}\s*:\s*(\w+)/)
          doc = extract_documentation(lines, line_num)
          return SymbolInfo.new(
            property_name, match[1], "setter", uri_to_filename(uri), line_num, line.strip, doc)
        end
        # @name : Type
        if match = line.match(/#{Regex.escape(property_name)}\s*:\s*(\w+)/)
          doc = extract_documentation(lines, line_num)
          return SymbolInfo.new(
            property_name, match[1], "instance_variable", uri_to_filename(uri), line_num, line.strip, doc)
        end
        # def initialize(@name : Type)
        if match = line.match(/def\s+initialize\([^)]*#{Regex.escape(property_name)}\s*:\s*(\w+)/)
          doc = extract_documentation(lines, line_num)
          return SymbolInfo.new(
            property_name, match[1], "instance_variable", uri_to_filename(uri), line_num, line.strip, doc)
        end
      end

      nil
    end

    private def is_method_available_for_type(symbol : SymbolInfo, receiver_type : String) : Bool
      case receiver_type
      when "String"
        return true if ["Object", "Reference", "Value"].includes?(symbol.type)
      when "Array"
        return true if ["Object", "Reference", "Enumerable", "Indexable"].includes?(symbol.type)
      when "Hash"
        return true if ["Object", "Reference", "Enumerable"].includes?(symbol.type)
      when "Int32", "Int64", "Float64", "Float32"
        return true if ["Object", "Value", "Number"].includes?(symbol.type)
      end

      symbol.type == "Object" || symbol.type == receiver_type
    end

    private def find_instance_variable_type(source : String, var_name : String) : String?
      lines = source.split('\n')
      clean_var_name = var_name.sub("@", "")

      lines.each do |line|
        if match = line.match(/property\s+#{Regex.escape(clean_var_name)}\s*:\s*(\w+)/)
          return match[1]
        end
        if match = line.match(/getter\s+#{Regex.escape(clean_var_name)}\s*:\s*(\w+)/)
          return match[1]
        end
        if match = line.match(/setter\s+#{Regex.escape(clean_var_name)}\s*:\s*(\w+)/)
          return match[1]
        end
        if match = line.match(/#{Regex.escape(var_name)}\s*:\s*(\w+)/)
          return match[1]
        end
        if match = line.match(/def\s+initialize\([^)]*#{Regex.escape(var_name)}\s*:\s*(\w+)/)
          return match[1]
        end
        if match = line.match(/#{Regex.escape(var_name)}\s*=\s*(.+)/)
          return infer_type_from_value(match[1].strip)
        end
      end

      nil
    end

    private def find_dot_before_position(line : String, pos : Int32) : Int32?
      (0...pos).reverse_each do |i|
        return i if line[i] == '.'
        break unless line[i].whitespace?
      end
      nil
    end

    private def extract_word_before_position(line : String, pos : Int32) : String?
      return nil if pos <= 0

      end_pos = pos - 1
      while end_pos >= 0 && line[end_pos].whitespace?
        end_pos -= 1
      end
      return nil if end_pos < 0

      start_pos = end_pos
      while start_pos > 0 && word_char?(line[start_pos - 1])
        start_pos -= 1
      end

      return nil if start_pos == end_pos + 1
      line[start_pos..end_pos]
    end

    private def get_receiver_type(source : String, receiver : String, current_line : Int32) : String?
      if receiver.starts_with?("@")
        return find_instance_variable_type(source, receiver)
      end

      return find_variable_type(source, receiver, current_line)
    end

    private def get_method_return_type(receiver_type : String, method_name : String) : String?
      case receiver_type
      when "String"
        case method_name
        when "size", "length"                                    then return "Int32"
        when "empty?", "starts_with?", "ends_with?", "includes?" then return "Bool"
        when "upcase", "downcase", "strip"                       then return "String"
        when "split"                                             then return "Array(String)"
        when "chars"                                             then return "Array(Char)"
        when "to_i"                                              then return "Int32"
        when "to_f"                                              then return "Float64"
        end
      when "Array"
        case method_name
        when "size", "length"       then return "Int32"
        when "empty?"               then return "Bool"
        when "first", "last", "pop" then return "T"
        when "join"                 then return "String"
        when "reverse", "sort"      then return receiver_type
        end
      when "Hash"
        case method_name
        when "size"               then return "Int32"
        when "empty?", "has_key?" then return "Bool"
        when "keys"               then return "Array(K)"
        when "values"             then return "Array(V)"
        end
      end

      if symbol = find_method_info(receiver_type, method_name)
        return symbol.type
      end

      "Object"
    end

    private def uri_to_filename(uri : String) : String
      return uri unless uri.starts_with?("file://")

      filename = uri.sub(/^file:\/\//, "")
      filename = URI.decode(filename)

      if filename =~ /^\/([a-zA-Z]):/
        filename = filename[1..]
      end

      filename.gsub('/', File::SEPARATOR)
    end
  end
end
