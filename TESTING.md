# Testing — OTP Buddy

## Unit

```bash
xcodebuild test -scheme OTPBuddy -destination 'platform=macOS'
```

Detector tests also covered in `shared-buddy` (`swift test`).

## UI / e2e

Smoke: launch, settings / status accessibility ids.

## CI

GitHub Actions: `xcodebuild test` on `macos-latest`.
