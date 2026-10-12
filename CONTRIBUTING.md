# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting set up

See [docs/app.md](docs/app.md) for the macOS app and [docs/cli.md](docs/cli.md) for the CLI. Both need Apple silicon.

## Tests and linting

```sh
macos/test.sh       # timeline math, planner rules, editing, signing and more
macos/playback-test.sh  # plays a built composition headlessly; fails on black or missing frames
macos/smoke-test.sh     # builds dist/ and drives the app's editor (needs a GUI session and Accessibility)

macos/lint.sh       # SwiftLint and ShellCheck (brew install swiftlint shellcheck)
```

CI runs all of these except the smoke test. Lint errors fail the build; SwiftLint warnings don't.

`test/make-fixture.sh` builds a synthetic project with speech, idle, typing and motion sections. Its green top bar grows 96 px per source second, so any rendered frame shows which source moment it came from.

## Pull requests

- Keep each PR to one change, and say how you tested it.
- Commit messages use `feat:`, `fix:` or `chore:` followed by a capitalized summary.
