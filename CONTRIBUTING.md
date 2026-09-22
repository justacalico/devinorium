# Contributing

## Development setup

- Backend: Rust. Run `cargo test` before submitting changes.
- Frontend: Flutter web under `flutter/`. Run `flutter test` and
  `flutter analyze` from that directory.
- Dev server: `cargo run -- --dev --local` binds a random loopback port with
  no login and an in-memory database. Plain `--dev` binds all interfaces
  without authentication; only use it when you need to reach the server from
  another machine.

## Commits

All commits must follow Conventional Commits (`<type>: <description>`) so
cocogitto can bump versions and generate the changelog. Valid types:
`feat`, `fix`, `chore`, `ci`, `docs`, `refactor`, `style`, `test`, `perf`,
`revert`, `build`, `misc`.

Install the commit-msg hook so non-conventional subjects get prefixed with
`misc:` automatically:

```bash
git config core.hooksPath .githooks
```

## Testing

- `cargo test` must pass.
- `cd flutter && flutter test` must pass.
- Add tests for new behavior in both the Rust backend and the Flutter
  frontend.
- Do not rely on CI status as a substitute for local verification.

## Merge requests

- Keep modules focused; do not create god files.
- Do not squash merge requests. Use a regular merge commit so each
  conventional commit is preserved for the changelog.
