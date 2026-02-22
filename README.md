# DeepDrift Secure 

A secure AI messenger with Cognitive Firewall visualization built with Flutter.

## Features

- **Anonymous Identity**: Random 6-digit Session ID (no phone numbers)
- **End-to-End Encryption**: FHRG-based KDF + ChaCha20-Poly1305
- **Neural Heartbeat**: Real-time semantic velocity monitoring
- **Dual Mode**: Live WebSocket connection or Demo mode simulation
- **Cognitive Firewall**: Visual alerts for semantic anomalies

## Installation

### Prerequisites

- Flutter SDK (3.0.0 or higher)
- Android SDK / Android Studio
- Android Emulator or physical device

### Setup

1. Extract the project files
2. Navigate to project directory:
   ```bash
   cd deepdrift_secure
   ```

3. Install dependencies:
   ```bash
   flutter pub get
   ```

4. Run on Android:
   ```bash
   flutter run
   ```

## Usage

### Login Screen

- **Server URL**: WebSocket endpoint (default: `ws://10.0.2.2:8000/chat`)
- **Encryption Key**: Shared secret (default: `Fractal_Universe_42`)
- **Demo Mode**: Toggle to simulate AI responses without server

### Demo Mode

Simulates:
- Streaming AI responses
- Deterministic velocity values
- WARNING and BLOCKED states
- Screen flash on firewall activation

### Live Mode

Requires WebSocket server at configured URL that accepts:
```json
{
  "payload": "<base64_encrypted_message>"
}
```

And responds with:
```json
{
  "payload": "<base64_encrypted_response>",
  "velocity": 0.42,
  "status": "OK | WARNING | BLOCKED"
}
```

## Semantic Cardiogram

- **Green**: Velocity < 0.8 (Safe)
- **Orange**: Velocity ≥ 0.8 (Warning)
- **Red**: Status = BLOCKED (Firewall activated)

## Security

- Messages encrypted with ChaCha20-Poly1305 AEAD
- Key derived using FHRG chaos-based KDF
- Encryption compatible with Python backend
- Session ID is display-only (not cryptographically sensitive)

## Android Configuration

The app is configured for Android. For Android Emulator:
- Use `10.0.2.2` to connect to localhost on host machine
- Enable internet permission (already configured in AndroidManifest.xml)

## Build for Release

```bash
flutter build apk --release
```

APK will be in: `build/app/outputs/flutter-apk/app-release.apk`
