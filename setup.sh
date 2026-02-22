#!/bin/bash

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         DeepDrift Secure - Installation Script            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if Flutter is installed
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter is not installed!"
    echo "Please install Flutter from: https://flutter.dev/docs/get-started/install"
    exit 1
fi

echo "✓ Flutter detected: $(flutter --version | head -n 1)"
echo ""

# Navigate to project directory
cd "$(dirname "$0")"

echo "📦 Installing dependencies..."
flutter pub get

if [ $? -eq 0 ]; then
    echo "✓ Dependencies installed successfully"
else
    echo "❌ Failed to install dependencies"
    exit 1
fi

echo ""
echo "🔧 Flutter Doctor Check..."
flutter doctor

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║                    Setup Complete!                         ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "To run the app:"
echo "  1. Connect an Android device or start an emulator"
echo "  2. Run: flutter run"
echo ""
echo "To build APK:"
echo "  flutter build apk --release"
echo ""
echo "Demo Mode: Toggle in app to test without server"
echo "Live Mode: Requires WebSocket server at ws://10.0.2.2:8000/chat"
echo "" 
