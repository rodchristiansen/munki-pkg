# Makefile for munkipkg
# Handles version generation, building, signing, and deployment

# Load environment from .env file if it exists
-include .env
export

# Configuration
SIGNING_IDENTITY ?= 
DEPLOY_PATH ?= /usr/local/bin
BINARY_NAME = munkipkg
BUILD_DIR = .build/release
BINARY_PATH = $(BUILD_DIR)/$(BINARY_NAME)

.PHONY: all build release clean test install version sign deploy deploy-unsigned sign-and-deploy help list-identities

# Default target
all: build

# Generate version file
version:
	@echo "Generating version file..."
	@VERSION=$$(date +"%Y.%m.%d.%H%M"); \
	echo "Generated version: $$VERSION"; \
	printf '%s\n' \
		'//' \
		'//  version.swift' \
		'//  munkipkg' \
		'//' \
		'//  Auto-generated file - DO NOT EDIT MANUALLY' \
		'//  Generated at build time with current timestamp' \
		'//' \
		'' \
		'/// Version string in YYYY.MM.DD.HHMM format based on build time' \
		"let VERSION = \"$$VERSION\"" \
		> munkipkg/version.swift

# Build debug version
build: version
	@echo "Building munkipkg (debug)..."
	@swift build

# Build release version
release: version
	@echo "Building munkipkg (release)..."
	@swift build -c release

# Run tests
test: version
	@echo "Running tests..."
	@swift test

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@swift package clean
	@rm -rf .build

# Sign the binary with Developer ID
sign: release
	@if [ -z "$(SIGNING_IDENTITY)" ]; then \
		echo "❌ SIGNING_IDENTITY not set. Either:"; \
		echo "   - Set environment variable: export SIGNING_IDENTITY='Developer ID Application: ...'";\
		echo "   - Create .env file with: SIGNING_IDENTITY=Developer ID Application: ...";\
		echo "   - Pass as argument: make sign SIGNING_IDENTITY='...'";\
		echo "   - Find available identities: security find-identity -v -p codesigning";\
		exit 1; \
	fi
	@echo "Signing $(BINARY_NAME) with identity: $(SIGNING_IDENTITY)"
	@codesign --sign "$(SIGNING_IDENTITY)" \
		--timestamp \
		--options runtime \
		--force \
		$(BINARY_PATH)
	@echo "✅ Signed successfully"
	@codesign -dvv $(BINARY_PATH) 2>&1 | grep "Authority" | head -1

# Deploy to specified directory (requires signing)
deploy: sign
	@echo "Deploying $(BINARY_NAME) to $(DEPLOY_PATH)..."
	@mkdir -p $(DEPLOY_PATH)
	@ditto $(BINARY_PATH) $(DEPLOY_PATH)/$(BINARY_NAME)
	@echo "✅ Deployed successfully to $(DEPLOY_PATH)/$(BINARY_NAME)"
	@$(DEPLOY_PATH)/$(BINARY_NAME) --version

# Deploy without signing (for local development)
deploy-unsigned: release
	@echo "Deploying $(BINARY_NAME) to $(DEPLOY_PATH) (unsigned)..."
	@mkdir -p $(DEPLOY_PATH)
	@cp $(BINARY_PATH) $(DEPLOY_PATH)/$(BINARY_NAME)
	@echo "✅ Deployed successfully to $(DEPLOY_PATH)/$(BINARY_NAME) (unsigned)"
	@$(DEPLOY_PATH)/$(BINARY_NAME) --version

# Sign and deploy (production workflow)
sign-and-deploy: deploy
	@echo "✅ Build, sign, and deploy complete!"

# Install to /usr/local/bin
install: release
	@echo "Installing munkipkg to /usr/local/bin..."
	@sudo cp $(BINARY_PATH) /usr/local/bin/
	@echo "Installation complete!"

# List available code signing identities
list-identities:
	@echo "Available code signing identities:"
	@security find-identity -v -p codesigning || echo "No code signing identities found"

# Display help
help:
	@echo "munkipkg Makefile"
	@echo ""
	@echo "Configuration:"
	@echo "  SIGNING_IDENTITY = $(or $(SIGNING_IDENTITY),<not set>)"
	@echo "  DEPLOY_PATH      = $(DEPLOY_PATH)"
	@echo ""
	@echo "Available targets:"
	@echo "  make                 - Build debug version (default)"
	@echo "  make build           - Build debug version"
	@echo "  make release         - Build release version"
	@echo "  make sign            - Build and code sign release binary (requires SIGNING_IDENTITY)"
	@echo "  make deploy          - Sign and deploy to DEPLOY_PATH (requires signing)"
	@echo "  make deploy-unsigned - Deploy without signing (for local development)"
	@echo "  make sign-and-deploy - Complete production workflow: build, sign, and deploy"
	@echo "  make test            - Run tests"
	@echo "  make clean           - Clean build artifacts"
	@echo "  make install         - Install release build to /usr/local/bin (requires sudo)"
	@echo "  make version         - Generate version file only"
	@echo "  make list-identities - Show available code signing identities"
	@echo "  make help            - Display this help message"
	@echo ""
	@echo "Configuration (via environment, .env file, or command line):"
	@echo "  SIGNING_IDENTITY     Code signing identity (required for signing)"
	@echo "  DEPLOY_PATH          Deployment destination (default: /usr/local/bin)"
	@echo ""
	@echo "Examples:"
	@echo "  make deploy-unsigned                    # Deploy without signing"
	@echo "  make sign SIGNING_IDENTITY='...'        # Sign with specific identity"
	@echo "  make deploy DEPLOY_PATH=/custom/path    # Deploy to custom path"
	@echo "  echo 'SIGNING_IDENTITY=...' > .env      # Set identity in .env file"
