require "../lsp/protocol"
require "file_utils"

module Liger
  class WorkspaceAnalyzer
    @workspace_root : String?
    @file_cache = Hash(String, String).new
    @symbol_cache = Hash(String, Array(SymbolInfo)).new
    @stdlib_cache = Hash(String, Array(SymbolInfo)).new
    @lib_cache = Hash(String, Array(SymbolInfo)).new
    @last_scan_time : Time?
    @stdlib_scanned = false
    @lib_scanned = false

    struct SymbolInfo
      property name : String
      property type : String
      property kind : String
      property file : String
      property line : Int32
      property signature : String?
      property documentation : String?

      def initialize(
        @name : String,
        @type : String,
        @kind : String,
        @file : String,
        @line : Int32,
        @signature : String? = nil,
        @documentation : String? = nil,
      )
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

    def get_class_members(class_name : String) : String?
      scan_workspace_if_needed
      members = [] of String

      class_symbol = nil
      @symbol_cache.each_value do |symbols|
        class_symbol = symbols.find { |s| s.kind == "class" && s.name == class_name }
        break if class_symbol
      end

      return nil unless class_symbol

      if content = @file_cache[class_symbol.file]?
        members = extract_type_members(content, class_name, "class")
      end

      members.empty? ? nil : members.join("\n")
    end

    def get_struct_members(struct_name : String) : String?
      scan_workspace_if_needed
      members = [] of String

      struct_symbol = nil
      @symbol_cache.each_value do |symbols|
        struct_symbol = symbols.find { |s| s.kind == "struct" && s.name == struct_name }
        break if struct_symbol
      end

      return nil unless struct_symbol

      if content = @file_cache[struct_symbol.file]?
        members = extract_type_members(content, struct_name, "struct")
      end

      members.empty? ? nil : members.join("\n")
    end

    private def extract_type_members(
      content : String,
      type_name : String,
      type_kind : String,
    ) : Array(String)
      lines = content.split('\n')
      members = [] of String
      in_type = false
      indent_level = 0

      lines.each do |line|
        if line.match(/^\s*#{type_kind}\s+#{Regex.escape(type_name)}\b/)
          in_type = true
          indent_level = line.size - line.lstrip.size
          next
        end

        if in_type
          current_indent = line.size - line.lstrip.size

          if line.match(/^\s*end\s*$/) && current_indent <= indent_level
            break
          end

          if line.match(/^\s*(?:class|struct|module|enum)\s+/) && current_indent > indent_level
            next
          end

          if match = line.match(/^\s*(?:private\s+)?def\s+(\w+)(?:\([^)]*\))?\s*(?::\s*(\w+))?/)
            method_name = match[1]
            return_type = match[2]? || "Object"
            members << "- `def #{method_name} : #{return_type}` (method)"
          elsif match = line.match(/^\s*(property|getter|setter)\s+(\w+)\s*:\s*(\w+)/)
            prop_kind = match[1]
            prop_name = match[2]
            prop_type = match[3]
            members << "- `#{prop_name} : #{prop_type}` (#{prop_kind})"
          elsif match = line.match(/^\s*@(\w+)\s*:\s*(\w+)/)
            var_name = match[1]
            var_type = match[2]
            members << "- `@#{var_name} : #{var_type}` (instance variable)"
          end
        end
      end

      members
    end

    def get_enum_values(enum_name : String, enum_file : String) : String?
      return nil unless File.exists?(enum_file)

      content = @file_cache[enum_file]? || File.read(enum_file)
      lines = content.split('\n')
      values = [] of String
      in_enum = false

      lines.each do |line|
        if line.match(/^\s*enum\s+#{Regex.escape(enum_name)}\b/)
          in_enum = true
          next
        end

        if in_enum
          if line.match(/^\s*end\s*$/)
            break
          elsif match = line.match(/^\s*(\w+)(?:\s*=\s*(.+))?/)
            value_name = match[1]
            value_expr = match[2]?
            if value_expr
              values << "- `#{value_name} = #{value_expr.strip}`"
            else
              values << "- `#{value_name}`"
            end
          end
        end
      end

      values.empty? ? nil : values.join("\n")
    end

    def find_symbol_info(symbol_name : String) : SymbolInfo?
      scan_workspace_if_needed

      if @symbol_cache.values.first?
        sample = @symbol_cache.values.first.first(10).map(&.name).join(", ")
      end

      is_qualified = symbol_name.includes?("::")

      if symbol_name.includes?("CrystGLFW") || symbol_name == "CrystGLFW"
        STDERR.puts "DEBUG find_symbol_info: Looking for '#{symbol_name}'"
        STDERR.puts "DEBUG find_symbol_info: is_qualified = #{is_qualified}"

        module_count = 0
        @symbol_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.kind == "module" && module_count < 5
              STDERR.puts "DEBUG find_symbol_info: Module in cache: #{symbol.name}"
              module_count += 1
            end
            if symbol.name.includes?("CrystGLFW")
              STDERR.puts "DEBUG find_symbol_info: Found symbol with CrystGLFW: #{symbol.name} (#{symbol.kind})"
            end
          end
        end
      end

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name == symbol_name
            return symbol
          end
        end
      end

      if is_qualified
        parts = symbol_name.split("::")
        if parts.size >= 2
          (parts.size - 1).downto(1) do |i|
            parent_namespace = parts[0...i].join("::")
            member_name = parts[i..-1].join("::")

            @symbol_cache.each_value do |symbols|
              symbols.each do |symbol|
                if symbol.name == parent_namespace &&
                   ["enum", "class", "module", "struct"].includes?(symbol.kind)
                  if found = find_member_in_file(symbol.file, member_name, symbol.line)
                    return found
                  end
                end
              end
            end
          end
        end

        @symbol_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.name == symbol_name
              return symbol
            end
          end
        end
      end

      scan_stdlib_if_needed

      if @stdlib_cache.values.first?
        sample = @stdlib_cache.values.first.first(10).map(&.name).join(", ")
      end

      @stdlib_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name == symbol_name
            return symbol
          end
        end
      end

      if is_qualified
        parts = symbol_name.split("::")
        if parts.size >= 2
          (parts.size - 1).downto(1) do |i|
            parent_namespace = parts[0...i].join("::")
            member_name = parts[i..-1].join("::")

            @stdlib_cache.each_value do |symbols|
              symbols.each do |symbol|
                if symbol.name == parent_namespace &&
                   ["enum", "class", "module", "struct"].includes?(symbol.kind)
                  if found = find_member_in_file(symbol.file, member_name, symbol.line)
                    return found
                  end
                end
              end
            end
          end
        end

        @stdlib_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.name == symbol_name
              return symbol
            end
          end
        end
      end

      unless is_qualified
        base_name = symbol_name.split("::").last

        @symbol_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.name.ends_with?("::#{base_name}")
              return symbol
            end
          end
        end

        @stdlib_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.name.ends_with?("::#{base_name}")
              return symbol
            end
          end
        end

        @lib_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.name.ends_with?("::#{base_name}")
              return symbol
            end
          end
        end
      end

      @lib_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name == symbol_name
            return symbol
          end
        end
      end

      if is_qualified
        parts = symbol_name.split("::")
        if parts.size >= 2
          (parts.size - 1).downto(1) do |i|
            parent_namespace = parts[0...i].join("::")
            member_name = parts[i..-1].join("::")

            @lib_cache.each_value do |symbols|
              symbols.each do |symbol|
                if symbol.name == parent_namespace &&
                   ["enum", "class", "module", "struct"].includes?(symbol.kind)
                  if found = find_member_in_file(symbol.file, member_name, symbol.line)
                    return found
                  end
                end
              end
            end
          end
        end

        @lib_cache.each_value do |symbols|
          symbols.each do |symbol|
            if symbol.name == symbol_name
              return symbol
            end
          end
        end
      end

      nil
    end

    def find_symbols_in_namespace(namespace : String) : Array(SymbolInfo)
      scan_workspace_if_needed

      results = [] of SymbolInfo
      search_pattern = "#{namespace}::"

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name.starts_with?(search_pattern)
            remainder = symbol.name[search_pattern.size..-1]
            unless remainder.includes?("::")
              results << symbol
            end
          end
        end
      end

      scan_stdlib_if_needed
      @stdlib_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name.starts_with?(search_pattern)
            remainder = symbol.name[search_pattern.size..-1]
            unless remainder.includes?("::")
              results << symbol
            end
          end
        end
      end

      results.uniq { |s| s.name }
    end

    def get_lib_functions(lib_name : String) : Array(SymbolInfo)
      scan_workspace_if_needed

      results = [] of SymbolInfo
      search_pattern = "#{lib_name}::"

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.kind == "fun" && symbol.name.starts_with?(search_pattern)
            results << symbol
          end
        end
      end

      scan_stdlib_if_needed
      @stdlib_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.kind == "fun" && symbol.name.starts_with?(search_pattern)
            results << symbol
          end
        end
      end

      results
    end

    def get_class_methods_and_properties(class_name : String) : Array(SymbolInfo)
      scan_workspace_if_needed

      STDERR.puts "DEBUG: get_class_methods_and_properties called for '#{class_name}'"

      results = [] of SymbolInfo

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name.starts_with?("#{class_name}::")
            if symbol.kind == "method" ||
               symbol.kind == "property" ||
               symbol.kind == "getter" ||
               symbol.kind == "setter" ||
               symbol.kind == "instance_variable"
              STDERR.puts "DEBUG: Found member in workspace cache: #{symbol.name} (#{symbol.kind})"
              results << symbol
            end
          end
        end
      end

      STDERR.puts "DEBUG: Found #{results.size} members in workspace cache"

      scan_stdlib_if_needed
      @stdlib_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name.starts_with?("#{class_name}::")
            if symbol.kind == "method" ||
               symbol.kind == "property" ||
               symbol.kind == "getter" ||
               symbol.kind == "setter" ||
               symbol.kind == "instance_variable"
              STDERR.puts "DEBUG: Found member in stdlib cache: #{symbol.name} (#{symbol.kind})"
              results << symbol
            end
          end
        end
      end

      @lib_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.name.starts_with?("#{class_name}::")
            if symbol.kind == "method" ||
               symbol.kind == "property" ||
               symbol.kind == "getter" ||
               symbol.kind == "setter" ||
               symbol.kind == "instance_variable"
              STDERR.puts "DEBUG: Found member in lib cache: #{symbol.name} (#{symbol.kind})"
              results << symbol
            end
          end
        end
      end

      STDERR.puts "DEBUG: Total members found: #{results.size}"

      results
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

      if word.match(/^[A-Z]\w*$/)
        return word
      end

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

      scan_directory(workspace_path, 0, exclude_lib: true)

      unless @lib_scanned
        lib_path = File.join(workspace_path, "lib")
        if Dir.exists?(lib_path)
          STDERR.puts "Scanning lib directory (one-time): #{lib_path}"
          scan_lib_directory(lib_path)
          @lib_scanned = true
        end
      end

      @last_scan_time = Time.utc
      total_symbols = @symbol_cache.values.sum(&.size) + @lib_cache.values.sum(&.size)
      STDERR.puts "Workspace scan complete. Found #{total_symbols} symbols"
    end

    private def scan_lib_directory(lib_path : String)
      Dir.each_child(lib_path) do |entry|
        shard_path = File.join(lib_path, entry)
        next unless Dir.exists?(shard_path)

        src_path = File.join(shard_path, "src")
        if Dir.exists?(src_path)
          scan_directory_for_lib(src_path, 0)
        end
      end
    end

    private def scan_directory_for_lib(path : String, depth : Int32)
      return if depth > 3

      Dir.each_child(path) do |entry|
        full_path = File.join(path, entry)

        if Dir.exists?(full_path)
          scan_directory_for_lib(full_path, depth + 1)
        elsif entry.ends_with?(".cr")
          scan_file_for_lib(full_path)
        end
      end
    end

    private def scan_file_for_lib(file_path : String)
      return unless File.exists?(file_path)

      scan_file(file_path)

      if symbols = @symbol_cache.delete(file_path)
        @lib_cache[file_path] = symbols
      end
    end

    private def scan_stdlib_if_needed
      return if @stdlib_scanned

      STDERR.puts "Lazy loading Crystal stdlib..."
      scan_stdlib
      @stdlib_scanned = true
    end

    private def scan_stdlib
      stdlib_path = detect_crystal_stdlib_path

      if stdlib_path && Dir.exists?(stdlib_path)
        STDERR.puts "Scanning Crystal stdlib: #{stdlib_path}"
        scan_stdlib_directory(stdlib_path, 0)
        return
      end

      stdlib_paths = [
        "/usr/share/crystal/src",
        "/usr/local/share/crystal/src",
        "/opt/crystal/src",
      ]

      stdlib_paths.each do |path|
        if Dir.exists?(path)
          STDERR.puts "Scanning Crystal stdlib: #{path}"
          scan_stdlib_directory(path, 0)
          break
        end
      end

      STDERR.puts "Stdlib scan complete. Found #{@stdlib_cache.values.sum(&.size)} stdlib symbols"
    end

    private def scan_stdlib_directory(path : String, depth : Int32)
      return if depth > 2

      Dir.each_child(path) do |entry|
        full_path = File.join(path, entry)

        if Dir.exists?(full_path)
          next if entry.starts_with?('.') || entry == "llvm" || entry == "crystal" || entry == "compiler"
          scan_stdlib_directory(full_path, depth + 1)
        elsif entry.ends_with?(".cr")
          scan_stdlib_file(full_path)
        end
      end
    end

    private def scan_stdlib_file(file_path : String)
      return unless File.exists?(file_path)

      content = File.read(file_path)
      symbols = [] of SymbolInfo
      lines = content.split('\n')
      current_namespace = [] of String

      lines.each_with_index do |line, line_num|
        if match = line.match(/^\s*class\s+(\w+)(?:\s*<\s*(\w+))?/)
          class_name = match[1]
          parent_class = match[2]? || "Object"
          full_name = (current_namespace + [class_name]).join("::")
          doc = extract_documentation(lines, line_num)

          symbols << SymbolInfo.new(full_name, parent_class, "class", file_path, line_num, line.strip, doc)

          current_namespace.push(class_name)
        elsif match = line.match(/^\s*module\s+(\w+)/)
          module_name = match[1]
          full_name = (current_namespace + [module_name]).join("::")
          doc = extract_documentation(lines, line_num)

          symbols << SymbolInfo.new(full_name, "Module", "module", file_path, line_num, line.strip, doc)

          current_namespace.push(module_name)
        elsif match = line.match(/^\s*struct\s+(\w+)/)
          struct_name = match[1]
          full_name = (current_namespace + [struct_name]).join("::")
          doc = extract_documentation(lines, line_num)

          symbols << SymbolInfo.new(full_name, "Struct", "struct", file_path, line_num, line.strip, doc)

          current_namespace.push(struct_name)
        elsif match = line.match(/^\s*enum\s+(\w+)/)
          enum_name = match[1]
          full_name = (current_namespace + [enum_name]).join("::")
          doc = extract_documentation(lines, line_num)

          symbols << SymbolInfo.new(full_name, "Enum", "enum", file_path, line_num, line.strip, doc)

          current_namespace.push(enum_name)
        elsif match = line.match(/^\s*lib\s+(\w+)/)
          # Track lib declarations for extern function bindings
          lib_name = match[1]
          full_name = (current_namespace + [lib_name]).join("::")
          doc = extract_documentation(lines, line_num)

          symbols << SymbolInfo.new(full_name, "Lib", "lib", file_path, line_num, line.strip, doc)
          current_namespace.push(lib_name)
        elsif match = line.match(/^\s*fun\s+(\w+)(?:\s*=\s*(\w+))?\s*(\([^)]*\))?\s*(?::\s*(.+))?/)
          # Track extern function declarations inside lib blocks
          fun_name = match[1]
          c_name = match[2]? || fun_name
          params = match[3]? || "()"
          return_type = match[4]? || "Void"

          # Store with lib namespace prefix
          full_name = current_namespace.empty? ? fun_name : (current_namespace.join("::") + "::" + fun_name)

          # Build signature for display
          signature = "fun #{fun_name}"
          signature += " = #{c_name}" if c_name != fun_name
          signature += params
          signature += " : #{return_type.strip}" unless return_type.strip.empty?

          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(full_name, return_type.strip, "fun", file_path, line_num, signature, doc)
        elsif match = line.match(/^\s*annotation\s+(\w+)/)
          current_namespace.push("__annotation__")
        elsif line.match(/^\s*end\s*$/)
          current_namespace.pop if current_namespace.any?
        elsif match = line.match(/^\s*def\s+(?:self\.)?(\w+)(?:\([^)]*\))?\s*(?::\s*(\w+))?/)
          method_name = match[1]
          return_type = match[2]? || "Void"
          full_method_name = current_namespace.empty? ? method_name : (current_namespace.join("::") + "::" + method_name)
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(full_method_name, return_type, "method", file_path, line_num, line.strip, doc)
        end
      end

      @stdlib_cache[file_path] = symbols
    end

    private def detect_crystal_stdlib_path : String?
      begin
        output = IO::Memory.new
        Process.run("crystal", ["env", "CRYSTAL_PATH"], output: output)
        crystal_path = output.to_s.strip

        paths = crystal_path.split({% if flag?(:windows) %} ';' {% else %} ':' {% end %})

        paths.each do |path|
          if path.ends_with?("/src") || path.ends_with?("\\src")
            if File.exists?(File.join(path, "prelude.cr")) || File.exists?(File.join(path, "object.cr"))
              return path
            end
          end
        end
      rescue
      end

      nil
    end

    private def scan_directory(path : String, depth : Int32 = 0, exclude_lib : Bool = false)
      return if depth > 10

      Dir.each_child(path) do |entry|
        full_path = File.join(path, entry)

        if Dir.exists?(full_path)
          next if entry.starts_with?('.') || entry == "bin"
          next if exclude_lib && entry == "lib"

          scan_directory(full_path, depth + 1, exclude_lib)
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
          symbols << SymbolInfo.new(
            class_name,
            parent_class,
            "class",
            file_path,
            line_num,
            line.strip,
            doc)
          symbols << SymbolInfo.new(
            full_name,
            parent_class,
            "class",
            file_path,
            line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(class_name)
        elsif match = line.match(/^\s*module\s+(\w+)/)
          module_name = match[1]
          full_name = (current_namespace + [module_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(
            module_name, "Module", "module", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, "Module", "module", file_path, line_num, line.strip, doc
          ) if current_namespace.any?
          current_namespace.push(module_name)
        elsif match = line.match(/^\s*lib\s+(\w+)/)
          lib_name = match[1]
          full_name = (current_namespace + [lib_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(lib_name, "Lib", "lib", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, "Lib", "lib", file_path, line_num, line.strip, doc
          ) if current_namespace.any?
          current_namespace.push(lib_name)
        elsif match = line.match(/^\s*fun\s+(\w+)(?:\s*=\s*(\w+))?\s*(\([^)]*\))?\s*(?::\s*(.+))?/)
          fun_name = match[1]
          c_name = match[2]? || fun_name
          params = match[3]? || "()"
          return_type = match[4]? || "Void"

          full_name = current_namespace.empty? ? fun_name : (current_namespace.join("::") + "::" + fun_name)

          signature = "fun #{fun_name}"
          signature += " = #{c_name}" if c_name != fun_name
          signature += params
          signature += " : #{return_type.strip}" unless return_type.strip.empty?

          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(fun_name, return_type.strip, "fun", file_path, line_num, signature, doc)
          symbols << SymbolInfo.new(full_name, return_type.strip, "fun", file_path, line_num, signature, doc) if current_namespace.any?
        elsif match = line.match(/^\s*annotation\s+(\w+)/)
          current_namespace.push("__annotation__")
        elsif line.match(/^\s*end\s*$/)
          current_namespace.pop if current_namespace.any?
        end

        scan_line_for_symbols(line, line_num, file_path, current_namespace, symbols, lines)
      end

      @symbol_cache[file_path] = symbols
    end

    private def scan_line_for_symbols(
      line : String,
      line_num : Int32,
      file_path : String,
      current_namespace : Array(String),
      symbols : Array(SymbolInfo),
      lines : Array(String),
    )
      # Enum definitions
      if match = line.match(/^\s*enum\s+(\w+)/)
        enum_name = match[1]
        full_name = (current_namespace + [enum_name]).join("::")
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(enum_name, "Enum", "enum", file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(
          full_name, "Enum", "enum", file_path, line_num, line.strip, doc) if current_namespace.any?
      end

      # Struct definitions
      if match = line.match(/^\s*struct\s+(\w+)/)
        struct_name = match[1]
        full_name = (current_namespace + [struct_name]).join("::")
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(struct_name, "Struct", "struct", file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(
          full_name, "Struct", "struct", file_path, line_num, line.strip, doc) if current_namespace.any?
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
        prop_name = match[1]
        prop_type = match[2]
        prop_kind_match = line.match(/^\s*(property|getter|setter)/)
        prop_kind = prop_kind_match ? prop_kind_match[1] : "property"
        full_prop_name = current_namespace.empty? ? "@#{prop_name}" : "#{current_namespace.join("::")}::@#{prop_name}"
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new("@#{prop_name}", prop_type, prop_kind, file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(full_prop_name, prop_type, prop_kind, file_path, line_num, line.strip, doc) if current_namespace.any?
      end

      # Instance variables
      if match = line.match(/^\s*@(\w+)\s*:\s*(\w+)/)
        var_name = "@#{match[1]}"
        var_type = match[2]
        full_var_name = current_namespace.empty? ? var_name : "#{current_namespace.join("::")}::#{var_name}"
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(
          var_name, var_type, "instance_variable", file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(
          full_var_name, var_type, "instance_variable", file_path, line_num, line.strip, doc) if current_namespace.any?
      end

      # Constants
      if match = line.match(/^\s*([A-Z][A-Z_]*)\s*=\s*(.+)/)
        const_name = match[1]
        const_value = match[2].strip
        const_type = infer_type_from_value(const_value)
        full_name = (current_namespace + [const_name]).join("::")
        doc = extract_documentation(lines, line_num)
        symbols << SymbolInfo.new(const_name, const_type, "constant", file_path, line_num, line.strip, doc)
        symbols << SymbolInfo.new(
          full_name, const_type, "constant", file_path, line_num, line.strip, doc) if current_namespace.any?
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
      namespace_indent_levels = [] of Int32

      lines.each_with_index do |line, line_num|
        line_indent = line.size - line.lstrip.size

        if match = line.match(/^\s*class\s+(\w+)(?:\s*<\s*(\w+))?/)
          current_class = match[1]
          parent_class = match[2]? || "Object"
          full_name = (current_namespace + [current_class]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(
            current_class, parent_class, "class", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, parent_class, "class", file_path, line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(current_class)
          namespace_indent_levels.push(line_indent)
        elsif match = line.match(/^\s*module\s+(\w+)/)
          current_module = match[1]
          full_name = (current_namespace + [current_module]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(current_module, "Module", "module", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, "Module", "module", file_path, line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(current_module)
          namespace_indent_levels.push(line_indent)
        elsif match = line.match(/^\s*lib\s+(\w+)/)
          lib_name = match[1]
          full_name = (current_namespace + [lib_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(lib_name, "Lib", "lib", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, "Lib", "lib", file_path, line_num, line.strip, doc) if current_namespace.any?
          current_namespace.push(lib_name)
          namespace_indent_levels.push(line_indent)
        elsif match = line.match(/^\s*fun\s+(\w+)(?:\s*=\s*(\w+))?\s*(\([^)]*\))?\s*(?::\s*(.+))?/)
          fun_name = match[1]
          c_name = match[2]? || fun_name
          params = match[3]? || "()"
          return_type = match[4]? || "Void"

          full_name = current_namespace.empty? ? fun_name : (current_namespace.join("::") + "::" + fun_name)

          signature = "fun #{fun_name}"
          signature += " = #{c_name}" if c_name != fun_name
          signature += params
          signature += " : #{return_type.strip}" unless return_type.strip.empty?

          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(fun_name, return_type.strip, "fun", file_path, line_num, signature, doc)
          symbols << SymbolInfo.new(full_name, return_type.strip, "fun", file_path, line_num, signature, doc) if current_namespace.any?
        elsif match = line.match(/^\s*annotation\s+(\w+)/)
          current_namespace.push("__annotation__")
          namespace_indent_levels.push(line_indent)
        elsif line.match(/^\s*end\s*$/)
          if current_namespace.any? && namespace_indent_levels.any?
            last_indent = namespace_indent_levels.last
            if line_indent <= last_indent
              popped = current_namespace.pop
              namespace_indent_levels.pop
              if popped == current_class
                current_class = nil
              elsif popped == current_module
                current_module = nil
              end
            end
          end
        end

        # Enum definitions
        if match = line.match(/^\s*enum\s+(\w+)/)
          enum_name = match[1]
          full_name = (current_namespace + [enum_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(enum_name, "Enum", "enum", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, "Enum", "enum", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Struct definitions
        if match = line.match(/^\s*struct\s+(\w+)/)
          struct_name = match[1]
          full_name = (current_namespace + [struct_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(struct_name, "Struct", "struct", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, "Struct", "struct", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Alias definitions
        if match = line.match(/^\s*alias\s+(\w+)\s*=\s*(.+)/)
          alias_name = match[1]
          alias_type = match[2].strip
          full_name = (current_namespace + [alias_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(alias_name, alias_type, "alias", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, alias_type, "alias", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Constants
        if match = line.match(/^\s*([A-Z][A-Z_]*)\s*=\s*(.+)/)
          const_name = match[1]
          const_value = match[2].strip
          const_type = infer_type_from_value(const_value)
          full_name = (current_namespace + [const_name]).join("::")
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(const_name, const_type, "constant", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(
            full_name, const_type, "constant", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Property declarations (property, getter, setter)
        if match = line.match(/^\s*property\s+(\w+)\s*:\s*(\w+)/)
          prop_name = match[1]
          prop_type = match[2]
          full_prop_name = current_namespace.empty? ? "@#{prop_name}" : "#{current_namespace.join("::")}::@#{prop_name}"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new("@#{prop_name}", prop_type, "property", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_prop_name, prop_type, "property", file_path, line_num, line.strip, doc) if current_namespace.any?
        elsif match = line.match(/^\s*getter\s+(\w+)\s*:\s*(\w+)/)
          prop_name = match[1]
          prop_type = match[2]
          full_prop_name = current_namespace.empty? ? "@#{prop_name}" : "#{current_namespace.join("::")}::@#{prop_name}"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new("@#{prop_name}", prop_type, "getter", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_prop_name, prop_type, "getter", file_path, line_num, line.strip, doc) if current_namespace.any?
        elsif match = line.match(/^\s*setter\s+(\w+)\s*:\s*(\w+)/)
          prop_name = match[1]
          prop_type = match[2]
          full_prop_name = current_namespace.empty? ? "@#{prop_name}" : "#{current_namespace.join("::")}::@#{prop_name}"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new("@#{prop_name}", prop_type, "setter", file_path, line_num, line.strip, doc)
          symbols << SymbolInfo.new(full_prop_name, prop_type, "setter", file_path, line_num, line.strip, doc) if current_namespace.any?
        end

        # Method definitions with return types
        if match = line.match(/^\s*def\s+(?:self\.)?(\w+)(?:\([^)]*\))?\s*:\s*(\w+)/)
          method_name = match[1]
          return_type = match[2]
          containing_type = current_namespace.join("::") || "Object"
          full_method_name = current_namespace.empty? ? method_name : "#{current_namespace.join("::")}::#{method_name}"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(full_method_name, return_type, "method", file_path, line_num, line.strip, doc)
        elsif match = line.match(/^\s*def\s+(?:self\.)?(\w+)(?:\([^)]*\))?/)
          method_name = match[1]
          return_type = infer_method_return_type(lines, line_num)
          containing_type = current_namespace.join("::") || "Object"
          full_method_name = current_namespace.empty? ? method_name : "#{current_namespace.join("::")}::#{method_name}"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(full_method_name, return_type, "method", file_path, line_num, line.strip, doc)
        end

        # Private method definitions
        if match = line.match(/^\s*private\s+def\s+(?:self\.)?(\w+)(?:\([^)]*\))?\s*:\s*(\w+)/)
          method_name = match[1]
          return_type = match[2]
          containing_type = current_namespace.join("::") || "Object"
          full_method_name = current_namespace.empty? ? method_name : "#{current_namespace.join("::")}::#{method_name}"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(full_method_name, return_type, "method", file_path, line_num, line.strip, doc)
        elsif match = line.match(/^\s*private\s+def\s+(?:self\.)?(\w+)(?:\([^)]*\))?/)
          method_name = match[1]
          return_type = infer_method_return_type(lines, line_num)
          containing_type = current_namespace.join("::") || "Object"
          full_method_name = current_namespace.empty? ? method_name : "#{current_namespace.join("::")}::#{method_name}"
          doc = extract_documentation(lines, line_num)
          symbols << SymbolInfo.new(full_method_name, return_type, "method", file_path, line_num, line.strip, doc)
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
          symbols << SymbolInfo.new(
            var_name,
            var_type,
            "instance_variable",
            file_path,
            line_num,
            line.strip,
            doc
          )
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

        if match = line.match(/def\s+\w+\([^)]*#{Regex.escape(var_name)}\s*:\s*(\w+)/)
          return match[1]
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

      if match = value.match(/^(\w+)\.new/)
        return match[1]
      end

      if match = value.match(/^(\w+)\.from_json/)
        return match[1]
      end

      if value.match(/^[A-Z]\w*$/)
        return value
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
      when "TextDocumentPositionParams"
        completions = ["text_document", "position"]
      when "TextDocumentIdentifier"
        completions = ["uri"]
      when "Position"
        completions = ["line", "character"]
      when "Location"
        completions = ["uri", "range"]
      when "CompletionParams"
        completions = ["text_document", "position", "context"]
      when "CompletionItem"
        completions = ["label", "kind", "detail", "documentation", "sort_text", "filter_text", "insert_text"]
      when "Hover"
        completions = ["contents", "range"]
      when "MarkupContent"
        completions = ["kind", "value"]
      when "Diagnostic"
        completions = ["range", "severity", "code", "source", "message"]
      when "TextDocumentManager", "SemanticAnalyzer", "WorkspaceAnalyzer", "CrystalParser"
        completions = ["new"]
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

      full_method_name = "#{receiver_type}::#{method_name}"

      @symbol_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.kind == "method"
            if symbol.name == full_method_name || symbol.name.ends_with?("::#{method_name}")
              if symbol.name.includes?(receiver_type)
                return symbol
              end
            end
          end
        end
      end

      @lib_cache.each_value do |symbols|
        symbols.each do |symbol|
          if symbol.kind == "method"
            if symbol.name == full_method_name || symbol.name.ends_with?("::#{method_name}")
              if symbol.name.includes?(receiver_type)
                return symbol
              end
            end
          end
        end
      end

      nil
    end

    private def find_property_in_source(
      source : String,
      property_name : String,
      uri : String,
    ) : SymbolInfo?
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

    # Find a member (enum value, constant, nested class, etc.) within a file
    private def find_member_in_file(file_path : String, member_name : String, parent_line : Int32) : SymbolInfo?
      content = @file_cache[file_path]?
      return nil unless content

      lines = content.split('\n')
      return nil if parent_line >= lines.size

      parent_indent = lines[parent_line].size - lines[parent_line].lstrip.size

      (parent_line + 1...lines.size).each do |line_num|
        line = lines[line_num]
        line_indent = line.size - line.lstrip.size

        if !line.strip.empty? && line_indent <= parent_indent && line.match(/^\s*(end|class|module|struct|enum)/)
          break
        end

        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?("#")

        if match = stripped.match(/^([A-Z]\w*)\s*(?:=|$)/)
          if match[1] == member_name
            range = LSP::Range.new(
              LSP::Position.new(line_num, line_indent),
              LSP::Position.new(line_num, line_indent + member_name.size)
            )
            return SymbolInfo.new(
              member_name,
              "EnumMember",
              "enum_member",
              file_path,
              line_num,
              stripped,
              nil
            )
          end
        end

        # Match nested classes
        if match = stripped.match(/^class\s+(\w+)/)
          if match[1] == member_name
            return SymbolInfo.new(
              member_name,
              "Class",
              "class",
              file_path,
              line_num,
              stripped,
              nil
            )
          end
        end

        # Match nested modules
        if match = stripped.match(/^module\s+(\w+)/)
          if match[1] == member_name
            return SymbolInfo.new(
              member_name,
              "Module",
              "module",
              file_path,
              line_num,
              stripped,
              nil
            )
          end
        end

        # Match nested structs
        if match = stripped.match(/^struct\s+(\w+)/)
          if match[1] == member_name
            return SymbolInfo.new(
              member_name,
              "Struct",
              "struct",
              file_path,
              line_num,
              stripped,
              nil
            )
          end
        end

        # Match constants
        if match = stripped.match(/^([A-Z][A-Z_]*)\s*=/)
          if match[1] == member_name
            return SymbolInfo.new(
              member_name,
              "Constant",
              "constant",
              file_path,
              line_num,
              stripped,
              nil
            )
          end
        end
      end

      nil
    end
  end
end
