# Liger Release Builder
# Builds cross-platform binaries for GitHub releases

VERSION := $(shell grep 'VERSION' src/liger.cr | sed 's/.*"\(.*\)".*/\1/')
BUILD_DIR := build

.PHONY: all clean help arm64-apple-darwin x86_64-pc-windows-msvc x86_64-unknown-linux-musl

all: local

# Detect current platform and build
local: $(BUILD_DIR)
	@echo "Building for current platform..."
	shards build liger --release --no-debug --stats --progress
	gzip -c bin/liger > $(BUILD_DIR)/liger_$$(uname -m)-$$(uname -s | tr '[:upper:]' '[:lower:]').gz
	@echo "Built: $(BUILD_DIR)/liger_$$(uname -m)-$$(uname -s | tr '[:upper:]' '[:lower:]').gz"

# macOS ARM64 (Apple Silicon)
arm64-apple-darwin: $(BUILD_DIR)
	@echo "Building for macOS ARM64..."
	shards build liger --release --no-debug --stats --progress
	gzip -c bin/liger > $(BUILD_DIR)/liger_arm64-apple-darwin.gz
	@echo "Built: $(BUILD_DIR)/liger_arm64-apple-darwin.gz"

# Windows x86_64
x86_64-pc-windows-msvc: $(BUILD_DIR)
	@echo "Building for Windows x86_64..."
	shards build liger --release --no-debug --stats --progress
	gzip -c bin/liger.exe > $(BUILD_DIR)/liger_x86_64-pc-windows-msvc.gz
	@echo "Built: $(BUILD_DIR)/liger_x86_64-pc-windows-msvc.gz"

# Linux x86_64 musl (requires Docker)
x86_64-unknown-linux-musl: $(BUILD_DIR)
	@echo "Building for Linux x86_64 musl..."
	@if ! command -v docker >/dev/null 2>&1 && ! command -v podman >/dev/null 2>&1; then \
		echo "Error: Docker or Podman required for Linux musl build"; \
		exit 1; \
	fi
	docker build -t liger .
	docker run --rm -v "$(PWD):/app/host" liger cp ./build/liger_x86_64-unknown-linux-musl.gz /app/host/build/
	@echo "Built: $(BUILD_DIR)/liger_x86_64-unknown-linux-musl.gz"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR) bin

clean:
	rm -rf $(BUILD_DIR) bin

help:
	@echo "Liger Release Builder"
	@echo ""
	@echo "Available targets:"
	@echo "  make local                    - Build for current platform"
	@echo "  make arm64-apple-darwin        - Build for macOS ARM64 (Apple Silicon)"
	@echo "  make x86_64-pc-windows-msvc    - Build for Windows x86_64"
	@echo "  make x86_64-unknown-linux-musl - Build for Linux x86_64 (requires Docker)"
	@echo "  make clean                     - Remove build artifacts"
	@echo "  make help                      - Show this help"
