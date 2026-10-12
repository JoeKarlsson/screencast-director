# Contributing

Thanks for helping. Bug reports, ideas and pull requests are all welcome.

## Getting set up

See [docs/cli.md](docs/cli.md) for the Node CLI and [docs/app.md](docs/app.md) for the macOS app. Both need Apple silicon.

## Tests

```sh
npm test            # timeline math and planner rules (TypeScript)
npm run typecheck
macos/test.sh       # the same checks in Swift
```

`test/make-fixture.sh` builds a synthetic project with speech, idle, typing and motion sections. Its green top bar grows 96 px per source second, so any rendered frame shows which source moment it came from.

## One rule to know

The planner, timeline math and look exist twice: in TypeScript (`scripts/`, `src/`) and in Swift (`macos/Sources/DirectorCore`). A change to one needs the same change in the other, and both test suites check the same cases.

## Pull requests

- Keep each PR to one change, and say how you tested it.
- Commit messages use `feat:`, `fix:` or `chore:` followed by a capitalized summary.
