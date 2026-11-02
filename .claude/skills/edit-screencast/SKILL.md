---
name: edit-screencast
description: Edit a recorded screencast in this repo by changing its plan.json (cuts, speed-ups, zooms, layouts, captions, callouts, annotations, motion), then verify and render. Use when the user says "edit my recording", "tighten this video", "zoom in when I...", "cut the part where...", or names a project under projects/.
---

# Edit a screencast

Arguments: a project name (folder under `projects/`), plus optional instructions.

## Plan rules that are easy to break

- All plan times are **source seconds** (positions in `screen.mp4`), never output seconds.
- `segments` must be ascending and non-overlapping. Anything not covered is cut.
- Segments with `speed > 1` render muted. Never speed up a segment where the user is talking.
- Zooms that touch hand off as a pan; a gap shorter than `style.transition` reads as a quick out-and-in.
- `zoom.x`/`zoom.y` are 0..1 fractions of the recorded screen; scale 1.4 to 2.2 looks natural.
- `sd plan` refuses to overwrite an existing `plan.json` (it may hold edits); `--force` regenerates.

## 1. Get the project ready

- If `projects/<name>/transcript.json` is missing, run `bin/sd analyze <name>`.
- If `plan.json` is missing, run `bin/sd plan <name>`. Never pass `--force` on a plan that may hold edits unless the user asks to start over.
- Run `bin/sd describe <name>` and read `plan.json`.
- Project files: `projects/<name>/` (gitignored): `screen.mp4`, `events.jsonl`, `source.json`, `transcript.json`, `motion.json`, `screentext.json` (OCR around each click, `DirectorCore/ScreenText.swift`; `describe` shows `on "Save"`), `plan.json`, `out.mp4`.

## 2. Edit pass

Apply the user's instructions first. If the project's `script.md` has an `## Edit plan` in its header (`describe` prints it), apply it too unless the user asked for one specific change: each line anchors an effect on quoted spoken words, so find them in `transcript.json` (the last kept take) and add the zoom, annotation, callout, animation (via `/animate`), sfx, punch-in, layout, transition, speed-up or insert it asks for. Take sounds from `sfx/` or the sound library, and B-roll only from `broll/` files that exist; list any the plan names that are missing, plus any line whose words were never said or are cut. The format is in `video-script-writer`'s `references/edit-plan.md` in the CData skills repo (`~/Documents/dev/cdata/skills`). Apply the header lines before the effects. `**Look:**` names a profile (`profile CData Explainer`): apply it with `director profile <project> "$HOME/Library/Application Support/Screencast Director/Profiles/<name>"`, then set `defaultLayout` from the rest of the line. `**Audio:**` sets `audio` (`normalize voice` is `normalize: true`, `warm voice` is `warm: true`, `+3 dB` is `gainDB: 3`). `**Camera:**` sets `camera`: copy the named LUT from `~/Movies/Screencast Director/LUTs/<name>.cube` into the project's `luts/` and point `grade.lut` at it (no other grade fields), set `bubbleSize`, and run `director frame-camera <project>` for `centered on face`. `**Music:**` replaces the profile's track only when it names a different one. That repo's `references/series-style.md` explains each setting and maps each kind of moment to its sound and level. Then make a quality pass unless they asked for only a specific change:

- **Retakes:** when the speaker says a sentence, stumbles, and says it again, keep only the last clean take. Look for repeated phrases in the transcript and for "sorry", "let me try that again", "wait".
- **Dead air:** gaps over ~0.6 s with nothing on screen should be cut; leave about 0.1 s on each side.
- **Speed:** typing or waiting with no narration should be sped up (3x typing, 4 to 8x for builds and installs). Never speed up narration.
- **Zooms:** when the speaker points at something ("this button", "up here in the config"), add or move a zoom to it. Use click positions from `events.jsonl` (via `describe`) to find where things are. Keep zooms at least ~1.5 s long and don't stack them so tight that the camera jitters.
- **Callouts:** short (2 to 5 word) titles at the start of each new section of the demo. `style` can be `lower-third` (a name with a `subtitle`), `slate` (full-screen opener or wrap) or `chapter` (section card).
- **Annotations:** when the speaker points at something small, a `box` or `arrow` (with a short `text` label) or a `spotlight` draws the eye; `blur` hides secrets on screen. The rectangle is x, y, w, h in 0..1 screen fractions and follows zooms.
- **Animations:** `animations` are motion-graphics explainers (templates filled with data, cued to spoken words) that play full frame. To add or change one, follow the `/animate` skill.
- **Sound effects:** each one lands on something that visibly appears (a chapter card, sticker, highlight, gag title, animation beat), never on a bare cut or punch-in, and the same kind of moment gets the same sound. Attach it to that item so it moves with it: `sound` (`file`, optional `gainDB`) on a callout or annotation plays at its start; an animation's `sounds` maps a cue name (or `start`) to one. Free-standing `sfx` (`t` in source seconds, `file`, `gainDB`, `note`) is only for moments with no item. A `file` is a sound in the project's `sfx/` or one from the sound library `describe` lists, written `sfx/<file>` (built-in CC0 sounds in `macos/Resources/sounds/` plus the user's own in `~/Library/Application Support/Screencast Director/Sounds/`), copied into the project when the video builds; they play unducked over the voice. `describe` lists them all and WARNs on an `sfx` in a cut.
- **Voice:** `audio.normalize` evens the voice out phrase by phrase, `audio.warm` makes it deeper and fuller (chest EQ, less boxiness, gentle compression, light saturation, soft top), `audio.cleanup` removes room noise, and `audio.gainDB` trims the level. Use them when the user says the voice sounds uneven, thin, boxy or noisy.
- **Music:** `music` (`file`, optional `volumeDB` and `duckDB`) is one background track, looped and ducked under the voice. Use a track from the music library `describe` lists (`music/advertime.m4a`; built-in CC0 tracks in `macos/Resources/music/` plus the user's own in `~/Library/Application Support/Screencast Director/Music/`), copied into the project when the video builds. Only add or change it when asked or when the edit plan's `**Music:**` names one.
- **B-roll and markers:** `inserts` show a picture or clip from the project folder (usually `broll/`) inside the screen card or full frame; only use files that exist. `markers` are the user's named points; use them when the user mentions one.
- **Motion:** `style.motion` (smooth, snappy, cinematic, bouncy) sets how zooms and overlays move; `enter`/`exit` on a callout or annotation overrides it (presets: fade, fade-up, slide-*, pop, zoom, blur, wipe, words, typewriter). `segments[i].transition` (crossfade, blur, dip, flash, punch, whip) styles the cut into a segment; keep those for section changes.
- **Punch-ins** (only with a camera): `camera.punchIns` (`start`, `end`, `scale` about 1.8 to 2.2, `note`) snap the camera tighter on the framing point for a beat and snap back, with no ease. Use a few (at most about four) on punchlines or key statements while the camera is large (`camera` layout), 1 to 2 s each.
- **Layouts** (only with a camera): `camera` for an intro or outro talking to the lens, `side` for explanations without screen action, `pip` elsewhere. A full-face stretch is a `camera` range in `layouts`, never `defaultLayout: camera`, which hides every demo. `describe` prints a WARNING wherever full camera covers clicks or typing; fix each one.
- Keep each segment's `note` meaningful; it shows up in `describe`.

## 3. Verify before rendering

- Run `bin/sd describe <name>` again and read it as a viewer would: does every cut land between sentences? Is any narration sped up? Is any layout WARNING left?
- Spot-check frames instead of rendering the whole video: render stills at the moments you changed and look at them (zoom framing, callout text, layout):
  `macos/.build/release/director still projects/<name> <frame> /tmp/f.png` (`still` writes only inside the project, e.g. `.checks/`, or a temp folder, and never through a symlink)

## 4. Render and report

- `bin/sd render <name>` writes `projects/<name>/out.mp4`. For a quick look, open the project in the Screencast Director app.
- Report the source and output length, and list what you changed in a few lines, with output timestamps so the user can jump to them.
