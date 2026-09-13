# Screenshots — OTP Buddy

```
docs/screenshots/{locale}/raw/
docs/screenshots/{locale}/banners/
```

Locales: `en`, `de`, `nl`, `pt`, `es`, `fr`, `it`, `ar`, `zh`, `ru`, `ja`.

Generate:

```bash
./scripts/generate-store-screenshots.sh
```

## Required shots

| ID | Feature | Banner title | Banner description |
|----|---------|--------------|-------------------|
| connect | Empty dashboard / add account | Connect your inbox | IMAP setup in a few steps |
| inbox | Main window with accounts + codes | Codes in one place | Browse recent OTPs across connected accounts |
| alert | Menu bar OTP popover | Codes when you need them | Menu bar alert with one-tap copy |
| autocopy | Auto-copy announcement | Instant clipboard | Optional auto-copy when a code arrives |
| pause | Pause / resume in pin | Pause when you need quiet | Stop watching until next session or a timed window |
| settings | Preferences | Preferences that fit you | Auto-copy, appearance, and launch-at-login |
