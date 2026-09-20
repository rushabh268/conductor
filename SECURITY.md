# Security

Conductor is a personal local desktop application. It reads sensitive native session history, so run only a build you trust. The application is not sandboxed: access to user-selected native history is part of its function. Do not treat its local database as encrypted storage.

Native Claude Code, Codex, and OpenCode history is read-only input. Configuration, hooks, plugins, permissions, and orchestration remain owned by those tools. Installation, upgrade, and uninstall scripts do not change them. Compass is optional and must be connected using a reader credential, never a ledger writer or identity key.

Do not include transcripts, prompts, API keys, reader credentials, personal paths, or session identifiers in public reports. Reproduce with synthetic fixtures and sanitized version/schema information. For a suspected vulnerability, use the repository host's private vulnerability reporting facility when enabled. If it is unavailable, request a private reporting channel without posting sensitive details.

The installer rejects symlink paths and unrelated bundle identities, and restricts destinations to the user's Applications directory. This prevents accidental replacement of unrelated applications; bundle identity is not a cryptographic authenticity guarantee. Checksums detect corruption, not publisher identity. Local packaging uses ad-hoc signing and does not claim notarization. The installer assumes the user's destination directory is not being maliciously modified concurrently by another process with the same user privileges.

Uninstall preserves the application index by default. Explicit `--purge-data` deletes only the validated Conductor Application Support directory; it does not erase native transcripts, preferences, backups, or exported files.

Optional Slack sharing stores its incoming-webhook credential in macOS Keychain. Only a reviewed Handoff preview is sent after an explicit Post action; redirects are refused. A migration failure retains the old preference and disables sharing until the credential can be saved safely. Uninstall preserves Keychain credentials; remove the sharing credential in Settings before uninstall if desired.
