# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting set up

See [docs/app.md](docs/app.md) for the macOS app and [docs/cli.md](docs/cli.md) for the CLI. Both need Apple silicon.

## Tests and linting

```sh
macos/test-all.sh   # everything below, in order; run it before pushing app changes
```

`test-all.sh` runs:

- `macos/lint.sh`: SwiftLint and ShellCheck (`brew install swiftlint shellcheck`)
- `macos/test.sh`: timeline math, planner rules, editing, review and more
- `macos/playback-test.sh`: plays a built composition headlessly; fails on black or missing frames
- `macos/media-test.sh`: the media pipeline on synthetic recordings and a talking-head clip (needs whisper-cli and a model)
- `macos/cli-test.sh`: every `director` command and `bin/sd` on a temp fixture
- `macos/animate-test.sh`: renders one animation per bundled template
- `macos/smoke-test.sh`: builds dist/ and drives the app's editor (needs a GUI session and Accessibility)

CI runs all of these except the smoke test. Lint errors fail the build; SwiftLint warnings don't.

`test/make-fixture.sh` builds a synthetic project with speech, idle, typing and motion sections. Its green top bar grows 96 px per source second, so any rendered frame shows which source moment it came from.

## Pull requests

- Keep each PR to one change, and say how you tested it.
- Commit messages use `feat:`, `fix:` or `chore:` followed by a capitalized summary.
- Add user-facing changes to the Unreleased section of [CHANGELOG.md](CHANGELOG.md).

## Releasing

Move the Unreleased notes under a new version heading, set `VERSION` to match, commit and push, then run `macos/release.sh`. It builds the app, tags the version and publishes a GitHub release with the zipped app and those notes.
