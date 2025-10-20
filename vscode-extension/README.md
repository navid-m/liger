# Liger - Crystal Language Support for VS Code

Full-featured Crystal language support for Visual Studio Code, powered by the Liger Language Server Protocol (LSP) implementation.

## Features

- **Syntax Highlighting** - Full Crystal syntax highlighting
- **Code Completion** - Intelligent code completion for keywords, types, methods, and variables
- **Diagnostics** - Real-time syntax error detection
- **Go to Definition** - Navigate to symbol definitions
- **Find References** - Find all references to a symbol
- **Hover Information** - View type information and documentation
- **Signature Help** - Parameter hints for method calls
- **Document Symbols** - Outline view of classes, modules, methods, and variables
- **Workspace Symbols** - Search symbols across your entire workspace
- **Rename Symbol** - Intelligent symbol renaming across files
- **Auto-closing Pairs** - Automatic closing of brackets, quotes, and pipes
- **Comment Toggling** - Easy comment/uncomment with `Ctrl+/`
- **Code Folding** - Fold/unfold code blocks

## Requirements

- **Liger Language Server** must be installed and accessible in your PATH
- Crystal compiler (>= 1.18.1) for building Liger

## Installation

### Install Liger Language Server

1. Clone and build Liger:
   ```bash
   git clone https://github.com/your-github-user/liger.git
   cd liger
   shards build --release
   ```

2. Add Liger to your PATH:
   
   **Windows (PowerShell):**
   ```powershell
   copy bin\liger.exe C:\Users\YourName\.local\bin\
   ```
   
   **Linux/macOS:**
   ```bash
   sudo cp bin/liger /usr/local/bin/
   ```

### Install VS Code Extension

1. **From VSIX** (if packaged):
   ```bash
   code --install-extension liger-crystal-0.1.0.vsix
   ```

2. **From source**:
   ```bash
   cd vscode-extension
   npm install
   npm run compile
   code --install-extension .
   ```

## Configuration

Configure the extension in your VS Code settings (`Ctrl+,` or `Cmd+,`):

```json
{
  // Path to Liger executable (default: "liger")
  "liger.serverPath": "liger",
  
  // Enable/disable features
  "liger.enableDiagnostics": true,
  "liger.enableCompletion": true,
  "liger.enableHover": true,
  "liger.enableDefinition": true,
  "liger.enableReferences": true,
  "liger.enableRename": true,
  "liger.enableDocumentSymbols": true,
  "liger.enableWorkspaceSymbols": true,
  
  // Maximum number of problems to show
  "liger.maxNumberOfProblems": 100,
  
  // Trace server communication (for debugging)
  "liger.trace.server": "off"  // "off" | "messages" | "verbose"
}
```

### Custom Server Path

If Liger is not in your PATH, specify the full path:

**Windows:**
```json
{
  "liger.serverPath": "C:\\Users\\YourName\\.local\\bin\\liger.exe"
}
```

**Linux/macOS:**
```json
{
  "liger.serverPath": "/usr/local/bin/liger"
}
```

## Usage

### Opening Crystal Files

Simply open any `.cr` file, and the extension will automatically activate and start the Liger language server.

### Commands

Access commands via the Command Palette (`Ctrl+Shift+P` or `Cmd+Shift+P`):

- **Liger: Restart Language Server** - Restart the Liger server
- **Liger: Show Liger Output** - Show the Liger output channel for debugging

### Keyboard Shortcuts

- `F12` - Go to Definition
- `Shift+F12` - Find All References
- `F2` - Rename Symbol
- `Ctrl+Space` - Trigger Code Completion
- `Ctrl+Shift+O` - Go to Symbol in File
- `Ctrl+T` - Go to Symbol in Workspace
- `Ctrl+K Ctrl+I` - Show Hover Information

## Features in Detail

### Code Completion

Type to get intelligent suggestions:
- Crystal keywords (`class`, `def`, `module`, etc.)
- Built-in types (`String`, `Int32`, `Array`, etc.)
- Context-aware suggestions based on your code

### Diagnostics

Real-time syntax error detection as you type. Errors are underlined in red with detailed messages.

### Go to Definition

Press `F12` or `Ctrl+Click` on a symbol to jump to its definition.

### Find References

Press `Shift+F12` to find all references to a symbol across your workspace.

### Rename Symbol

Press `F2` on a symbol to rename it across all files. Liger intelligently finds and updates all occurrences.

### Document Outline

View the structure of your Crystal file in the Outline panel (Explorer sidebar).

### Workspace Symbols

Press `Ctrl+T` and type to search for classes, modules, methods, and constants across your entire workspace.

## Troubleshooting

### Server Not Starting

1. **Check if Liger is installed:**
   ```bash
   liger --version
   ```

2. **Check the output channel:**
   - Open Command Palette (`Ctrl+Shift+P`)
   - Run "Liger: Show Liger Output"
   - Check for error messages

3. **Verify the server path:**
   - Open Settings (`Ctrl+,`)
   - Search for "liger.serverPath"
   - Ensure the path is correct

### Conflicts with Other Crystal Extensions

If you have other Crystal extensions installed, they may conflict. Disable or uninstall them:

1. Open Extensions view (`Ctrl+Shift+X`)
2. Search for "crystal"
3. Disable or uninstall other Crystal extensions

### Performance Issues

If the language server is slow:

1. Reduce the number of open files
2. Close unused workspaces
3. Disable features you don't need in settings

### Debug Mode

Enable verbose logging to diagnose issues:

```json
{
  "liger.trace.server": "verbose"
}
```

Then check the output channel for detailed communication logs.

## Known Limitations

- **Type Inference**: Full type inference is not yet implemented. Go to definition and some hover information may be limited.
- **Cross-file Analysis**: Some features work best within a single file currently.
- **Macro Expansion**: Macro expansion is not yet supported.

## Comparison with Other Extensions

| Feature | Liger | Official Crystal Extension |
|---------|-------|---------------------------|
| Windows Support | ✅ | ❌ |
| Code Completion | ✅ | ✅ |
| Diagnostics | ✅ | ✅ |
| Go to Definition | ✅ | ✅ |
| Find References | ✅ | ⚠️ |
| Rename Symbol | ✅ | ❌ |
| Document Symbols | ✅ | ✅ |
| Workspace Symbols | ✅ | ✅ |

## Contributing

Contributions are welcome! Please visit the [GitHub repository](https://github.com/your-github-user/liger) to:

- Report bugs
- Request features
- Submit pull requests

## License

MIT License - see [LICENSE](../LICENSE) file for details.

## Links

- [GitHub Repository](https://github.com/your-github-user/liger)
- [Issue Tracker](https://github.com/your-github-user/liger/issues)
- [Crystal Language](https://crystal-lang.org/)

## Changelog

### 0.1.0 (Initial Release)

- Initial release with full LSP support
- Code completion, diagnostics, and navigation features
- Rename symbol functionality
- Windows support
- Cross-platform compatibility
