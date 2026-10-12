# Screencast Director

Record your screen, then tell Claude how to edit it.

Screencast Director gives you Screen Studio-style polish (auto-zoom on clicks, sped-up typing, cut dead air, captions, a camera bubble) without the timeline dragging. The edit is driven by what you **say**: Whisper word timestamps decide what's a retake, when typing can be fast-forwarded, and where a zoom belongs. The result is a plain JSON plan that you, Claude, or any LLM can rewrite in plain language.

<!-- Hero GIF: 10-15 s of a raw recording turning into the edited version.
![Screencast Director turning a raw recording into an edited video](docs/media/hero.gif)
-->

## Features

- **Talking rule:** speech plays at 1x, typing without narration at 3x, dead air is cut, "um" and "uh" are removed.
- **Auto-zoom** on clusters of clicks and typing, chained into smooth pans.
- **Edit by asking:** "cut my retakes and zoom in when I mention the config file." Every AI edit is one ⌘Z away.
- **Captions, titles, camera layouts** (picture-in-picture, side-by-side, full camera).
- **Any format:** 16:9, 9:16, 1:1 or 4:5, up to 4K, with vertical crops that follow the action.
- **Publishing kit:** SRT captions, YouTube chapters, a drafted description and thumbnail candidates.
- **Private by default:** transcription runs on your Mac. Keystrokes are logged without characters.

<!-- Screenshot: the editor with the timeline, preview and inspector.
![The editor: preview, timeline and inspector](docs/media/editor.png)
-->

## Two ways to use it

| | macOS app | CLI |
|---|---|---|
| **For** | Recording and editing with a GUI | Scripting, or editing with Claude Code |
| **Needs** | Apple silicon, macOS 15+ | macOS, Node 22.18+, ffmpeg, mlx-whisper |
| **Renders with** | AVFoundation (fast, native) | [Remotion](https://www.remotion.dev) |
| **Docs** | [docs/app.md](docs/app.md) | [docs/cli.md](docs/cli.md) |

Both read and write the same project format, described in [docs/plan-format.md](docs/plan-format.md).

### macOS app

```sh
brew install whisper-cpp
macos/build.sh --install      # builds /Applications/Screencast Director.app
```

Press ⌃⌥⌘R in any app to record. When you stop, the app transcribes, drafts an edit and opens the editor.

### CLI

```sh
npm install && logger/build.sh
cp sd.env.example sd.env      # set devices from `sd devices`

bin/sd record demo --camera   # screen, mic, camera, plus a click and keystroke log
bin/sd auto demo              # transcribe, draft an edit, render projects/demo/out.mp4
claude "/edit-screencast demo cut my retakes and zoom in when I mention the config file"
bin/sd render demo
```

## AI providers

Edits can come from **Claude Code** (default, uses your Claude login), the **Anthropic API**, or any **OpenAI-compatible endpoint** (OpenAI, OpenRouter, LiteLLM, Ollama).

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup and tests.

## License

[MIT](LICENSE). Rendering with the CLI uses Remotion, which is free for individuals and companies of up to three people; larger companies need a [Remotion company license](https://www.remotion.dev/license). The macOS app does not use Remotion.
