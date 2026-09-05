# OTP Buddy

Menu-bar OTP helper: IMAP inbox watch → detect code → copy to clipboard.

```bash
ln -sfn ../../shared-buddy Vendor/shared-buddy
xcodegen generate
xcodebuild -scheme OTPBuddy -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

Use an app password (Gmail/Outlook). OAuth2 can be wired on the same IMAP command path later.
