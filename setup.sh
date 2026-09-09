#!/bin/bash
set -e

echo "Setting up Teleprompter project..."

# Check for Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "Error: Xcode not found. Install from the App Store."
    exit 1
fi

# Check for xcodegen
if ! command -v xcodegen &> /dev/null; then
    echo "Installing xcodegen via Homebrew..."
    if ! command -v brew &> /dev/null; then
        echo "Error: Homebrew not found. Install from https://brew.sh"
        exit 1
    fi
    brew install xcodegen
fi

# Build core package first
echo "Building TeleprompterCore..."
cd TeleprompterCore && swift build && cd ..

# Generate Xcode project
echo "Generating Xcode project..."
xcodegen generate

echo ""
echo "Done! Open Teleprompter.xcodeproj in Xcode."
echo ""
echo "Alternatively, open the package directly:"
echo "  open TeleprompterCore/Package.swift"
