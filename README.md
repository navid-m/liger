# Liger

A comprehensive Language Server Protocol (LSP) implementation for the Crystal programming language, designed to work cross-platform with a focus on Windows compatibility.

## Features

Liger provides a more extensive feature set than existing Crystal language servers (Crystalline, Scry), with full Windows support:

### Core LSP Features
- **Text Document Synchronization** - Full document sync with change tracking
- **Diagnostics** - Real-time syntax and semantic error detection
- **Code Completion** - Context-aware completions for keywords, types, methods, and variables
- **Hover Information** - Type information and documentation on hover
- **Signature Help** - Parameter hints for method calls
- **Go to Definition** - Navigate to symbol definitions
- **Find References** - Find all references to a symbol
- **Document Symbols** - Outline view of classes, methods, and variables
- **Workspace Symbols** - Search symbols across the entire workspace
- **Rename Symbol** - Intelligent symbol renaming (advanced feature beyond Crystalline)

### Platform Support
- **Windows** - Native Windows support (primary focus)
- **Linux** - Full Linux compatibility
- **macOS** - macOS support

## Installation

### Prerequisites
- Crystal compiler (>= 1.18.1)
- Git
