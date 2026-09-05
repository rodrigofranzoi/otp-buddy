# OTP Buddy Features

Status: `planned` | `wip` | `done`

| Feature | Status | Notes |
|---------|--------|-------|
| Attach email via IMAP (app password / host settings) | done | OAuth2 hooks stubbed; app password path works |
| Inbox watcher | done | Poll IMAP UNSEEN / recent |
| OTP detection (BuddyCore) | done | |
| Auto-copy setting | done | |
| Menu bar popup: new OTP / copied | done | |
| Keychain credentials | done | |
| Privacy: codes in-memory TTL | done | |
| Unit + UI tests | done | |
| Localization (10 locales) | done | |
| Firebase | done | |

## Feasibility notes

MailKit alone cannot reliably read full bodies for OTP extraction. IMAP (local credentials in Keychain) is the supported approach.
