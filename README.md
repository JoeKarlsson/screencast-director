# Screencast Director

A macOS app that records your screen and does the boring part of the edit. Talk through your demo once: it cuts the dead air, speeds up typing, zooms to your clicks and captions what you said. Then adjust it by hand, or tell Claude what to change.

<!-- Hero GIF: 10-15 s of a raw recording turning into the edited version.
![Screencast Director turning a raw recording into an edited video](docs/media/hero.gif)
-->

## Install

Apple silicon, macOS 15+, the Xcode Command Line Tools, and `brew install whisper-cpp`.

```sh
macos/build.sh --install      # builds /Applications/Screencast Director.app
```

On first launch, **Getting Started** shows which permissions are missing and plays a 3-minute tour.

## Use it

1. **Record:** press ⌃⌥⌘R in any app, talk through your demo, then press it again.
2. **Draft:** it transcribes on your Mac and drafts the edit. Talking plays in real time, typing without talking is sped up, and silence is cut.
3. **Adjust:** use the timeline and inspector. The shortcuts match Screen Studio's, and ⌘/ lists them.
4. **Or ask:** "cut my retakes and zoom in when I mention the config." ⌘Z undoes it.
5. **Export or publish:** 16:9, 9:16, square or 4:5, up to 4K, plus captions, chapters, a description draft and thumbnails.

## Features

- **Timeline:** clips, an audio waveform, words, zooms, layouts and titles.
- **Pauses:** Gentle, Normal or Tight, measured from the audio. Cuts that removed words stay cut.
- **Camera:** bubble, side by side or full frame, auto-centered on your face, with reframing and color grading.
- **Sound:** voice normalizing, volume and a limiter.
- **Profiles:** your look (background, fonts, colors, logo, frame), full bleed or padded.
- **AI:** Claude Code (your Claude login, no key), the Anthropic API, or any OpenAI-compatible endpoint.
- **Library:** search by name or by what you said, and let Claude name recordings.

Details: [docs/app.md](docs/app.md). The older scriptable CLI, which renders with Remotion, is in [docs/cli.md](docs/cli.md). Both use the project format in [docs/plan-format.md](docs/plan-format.md).

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md). [MIT](LICENSE). The CLI's Remotion renderer needs a [company license](https://www.remotion.dev/license) for teams of more than three people; the app doesn't use Remotion.
