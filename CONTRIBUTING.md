# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting set up

See [docs/cli.md](docs/cli.md) for the Node CLI and [docs/app.md](docs/app.md) for the macOS app. Both need Apple silicon.

## Tests and linting

```sh
npm test            # timeline math and planner rules (TypeScript)
npm run typecheck
macos/test.sh       # the same checks in Swift
macos/playback-test.sh  # plays a built composition headlessly; fails on black or missing frames
macos/smoke-test.sh     # builds dist/ and drives the app's editor (needs a GUI session and Accessibility)

npm run lint        # ESLint for TypeScript, ShellCheck for the shell scripts
macos/lint.sh       # SwiftLint (brew install swiftlint shellcheck)
```

CI runs all of these except the smoke test. Lint errors fail the build; SwiftLint warnings don't.

`test/make-fixture.sh` builds a synthetic project with speech, idle, typing and motion sections. Its green top bar grows 96 px per source second, so any rendered frame shows which source moment it came from.

## One rule to know

The core planner rules and timeline math exist twice: in Swift (`macos/Sources/DirectorCore`, the main engine) and in TypeScript (`scripts/`, `src/`, the legacy CLI path). A change to the shared rules needs the same change in both, and both test suites check the same cases. Newer features (easing, cursor, word snapping, profiles, retakes, script takes) are Swift-only.

## Pull requests

- Keep each PR to one change, and say how you tested it.
- Commit messages use `feat:`, `fix:` or `chore:` followed by a capitalized summary.
