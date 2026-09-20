# Reader compatibility

Conductor presents a common workspace for Claude Code, Codex, and OpenCode. Compatibility depends on the actual native format, not only a marketing version number. Tests use synthetic native-format fixtures; they do not claim coverage for every released client version.

| Source | Local input | Capability boundary |
| --- | --- | --- |
| Claude Code | Project/session JSONL and supported session metadata | Parent relationships require explicit metadata or supported subagent containment. |
| Codex | Read-only SQLite session metadata and referenced JSONL history | Supported schema fields and source shapes are checked; unsupported data must not trigger native repair. |
| OpenCode | Read-only local session/message storage | Native parent IDs and supported message fields are used; a local server is not started automatically. |
| Compass (optional) | Versioned local reader API | A reader credential and compatible running service are required; native browsing works without them. |

Missing token fields are not measured zero usage. Unknown model prices cannot establish cost. Session activity timestamps are not proof of task completion. Unsupported parent information cannot safely be guessed from titles, paths, or nearby timestamps.

When reporting compatibility problems, include a sanitized schema/format description and a synthetic minimal fixture. Do not upload real databases or transcripts. Never run setup, login, repair, or hook installation to make a compatibility test pass.

SQLite metadata scans use a single read-only snapshot, released before local index writes. A changed native fingerprint triggers full metadata reconciliation, including historical imports with old timestamps. Each scan admits at most 10,000 sessions and 16 MiB of selected metadata values. Exceeding either bound reports a reader error and leaves the previous index/checkpoint intact; it does not silently mark a partial scan complete. Unchanged fingerprints skip rescanning. These are supported input bounds, not a benchmark claim.

JSONL reads retain bounded incremental offsets and use SHA-256 for two generation windows: up to the first 4 KiB and up to 4 KiB immediately before the consumed checkpoint offset. A change in either window resets accumulated state; ordinary appends preserve offsets. The checkpoint binds its tail hash to its offset, and older fingerprint formats reset once without a database migration. Generation checks read at most 8 KiB in addition to the transcript byte budget. A rewrite that preserves both sampled windows and regrows beyond the old offset remains an unsupported case that this bounded detector cannot always distinguish from append.
