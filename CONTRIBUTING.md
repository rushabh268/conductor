# Contributing

Use Xcode, XcodeGen 2.46.0, Python 3, and macOS 14 or later. Run `./scripts/test.sh` and `./scripts/build.sh` before proposing a change. The generated Xcode project and build products are ignored. Update `Conductor/project.yml` instead of editing the generated project. Keep the GRDB exact version and `Conductor/Package.resolved` consistent.

Tests must create synthetic, temporary profiles and databases. Never create, modify, or delete files in a developer's real Claude Code, Codex, or OpenCode profile. Never enable native hooks/plugins, run setup/login/repair flows, or bootstrap Compass as part of tests. The test scheme sets `CONDUCTOR_TEST_MODE=1` so the app host does not initialize production state.

Reader changes need fixtures for main/child/unknown identities, missing fields, malformed or partial input, pagination, and read-only access. Missing source capabilities need a visible unavailable reason. Keep raw transcripts and credentials out of logs and exports by default.

Installer changes need temporary-directory tests covering preservation, invalid arguments, unsafe paths, symlinks, updates, and rollback. `python3 -m unittest discover -s scripts/tests` runs those tests without building or installing the app.

Documentation and examples must be suitable for a public personal project: synthetic names and paths, no workplace-specific configuration, private URLs, or secrets. Historical private planning and Git history are not distribution assets.

Keep changes focused and explain behavior, validation, and limitations in the pull request. Contributions are licensed under the MIT License.
