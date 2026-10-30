# screencast-director

Record the screen, then edit by changing a JSON plan. Everything runs on the Swift engine in `macos/` (the app and the `director` CLI). Claude's job is usually to edit `projects/<name>/plan.json` from the user's instructions (use the `/edit-screencast` skill).

- `bin/sd`: the CLI (devices, record, import, analyze, plan, describe, render, auto). Recording uses ffmpeg; analyze/plan/describe/render run `macos/.build/release/director`, building it on first use.

- Build with `macos/build.sh` (version from `VERSION`, build number from the commit count); release with `macos/release.sh` after adding a CHANGELOG.md section. Add user-facing changes to CHANGELOG.md under Unreleased.

Area detail loads from `.claude/rules/` when you touch matching files (`macos.md` for the Swift engine and app, `recording.md` for `bin/`); plan rules and verification live in the `/edit-screencast` skill.
