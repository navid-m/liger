#!/bin/bash
# Setup script for Liger VS Code Extension
# Run this to install dependencies and build the extension

set -e

echo "Setting up Liger VS Code Extension..."

if ! command -v node &> /dev/null; then
    echo "Error: Node.js is not installed. Install Node.js first."
    exit 1
fi

echo "Node.js version: $(node --version)"
echo ""
echo "Installing dependencies..."
npm install

echo ""
echo "Compiling TypeScript..."
npm run compile

echo ""
echo "Packaging extension..."
npm run package

echo ""
echo "✓ Extension built successfully!"
echo ""
echo "To install the extension, run:"
echo "  code --install-extension liger-crystal-0.1.0.vsix"
