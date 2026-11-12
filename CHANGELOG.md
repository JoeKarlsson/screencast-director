# Changelog

Each release lists what changed for people using the app or the CLI. The version lives in `VERSION`; `macos/release.sh` tags it and publishes the build.

## Unreleased

### Security
- A project folder someone sends you can no longer reach outside itself:
  - The app and `director` refuse to write or delete through a project folder that's a symlink: `.animations`, `broll`, `animations/` and its `logos`, `templates` and `lottie` folders, `effects`, `.render`, `.history`, `.checks`, `publish`, `sfx` and `music`. Before, a `.animations` symlink made opening the project empty the folder it pointed to.
  - Animations render in a page that reads only the app's own animation files and has no network. Logos and fonts reach it through a list made for each render, so a template that came with a project can't load other files on your Mac or send anything out.
  - Its `logos.json` can only name files in its own logos folder.
- `still`, `contact-sheet` and `animate-test` write only into the project's `.checks/` folder or a temp folder, as a `.png` (`animate-test` as an `.mp4`). Before, `still . 0 screen.mp4` could overwrite the recording.
- Template names can only use letters, digits, `-` and `_`. Before, `template update` with a `../` name could delete any `.js` file.
- `director capture` fetches a page's logo only over http(s), or as a local file beside a local page, and only on a successful response. It writes nothing through a symlink.
- Stock and Openverse downloads:
  - The file name made from an empty title is cleaned the same as a title.
  - A license record is never appended through a symlink.
  - ffmpeg reads only local files.
- An AI edit can't point a clip's logo outside the project: PathSafety now covers `clips[].logo`.
- `look.accent` reaches the animation page only as a hex color.
- The Claude box can't mark a secret safe to show: `director secrets --allow` refuses to run under `SD_ONLY_PROJECT`.
- Links:
  - A `screencastdirector://` discard or restart moves the take to the Trash instead of deleting it.
  - `open?project=` for a folder outside the projects folder asks before opening it.
- `sd import` only accepts a video whose extension is letters and digits, and ffprobe reads only local files.

### Claude box
- Rewind to before any ask: the ↺ beside an ask in the Claude box puts the plan back to how it was before it, undoing that ask and every edit after it in one step (⌘Z brings them back). Rewound asks are dimmed, and Claude starts a fresh conversation. Agents do the same with `director asks <dir>` and `director asks <dir> rewind <n>`. Asks from before this version can't be rewound to.
- Each finished ask keeps the steps it took in a folded line ("8 steps · 1 failed · 42 s"), which opens to every step with ✓ or ✗ and how long it ran, so you can see what failed. While it runs, a step that fails shows ✗ right away.

### Cursor, zooms and cuts
- The drawn cursor lands exactly on every click: heavy smoothing used to leave the tip beside the button it clicked, so it now eases onto the click's own point a quarter second before, holds, and eases back after.
- The drawn cursor fades out after resting 1.5 s and fades back in just before it moves, so a still pointer doesn't sit on the screen while you talk. Cursor & Overlays > Hide when still turns it off (`cursor.idleHide: false`); screen effects that follow the pointer still follow it.
- Cutting words in the transcript takes the pause after them too, up to 70 ms before the next word, so deleting a sentence leaves one natural pause instead of two. Any cut (the timeline, the transcript, `director cut`) also takes a leftover piece under two frames beside it, which would only flash by.
- Drafted zooms are steadier: the video opens wide for its first 2.5 s, the click that stops the recording gets no zoom, clicks that drift further than one zoomed view can show become two zooms, and two zooms less than 1.5 s apart pan from one to the next instead of zooming out and straight back in.

### Editor
- Settings with a few options show them all as a row of choices instead of a menu or segmented control: frame style, animation theme, chapter style, shape, resolution, frame rate, screen crop, camera shape and room, pauses, effect layers, the logo's corner and B-roll placement. Cursor smoothing picks Off, Light, Medium or Strong (a value set between them shows as Custom).
- The inspector is quieter: the explanations under settings moved into their tooltips, and controls that can't apply right now are hidden instead of greyed out (nudging items that can't move, reordering a single clip, Repeat at Playhead with the playhead inside the clip, layouts without a camera).
- The timeline shows the selected bar with a halo in its own color, shows a dragged edge's in and out times above it, and outlines how far a clip can grow while you trim it (in recording time).
- One type scale, spacing scale and set of corner radii across the inspector, timeline, Claude box and recording setup, with rounder cards.
- Calmer motion: nothing in the editor bounces any more. Banners and the recording widget slide or fade in and leave a little faster than they came; panels and folds ease at both ends; recording cards no longer grow or lift on hover. With Reduce Motion on in System Settings, panels, banners and folds change at once and the recording dot stops breathing.
- A flatter look: no gradient behind Home or the preview, no glossy sheen on timeline bars, no glow on the playhead, the app icon, the recording dot or the AI edit highlight, and no shadows or outlines on cards.

### Retention
- `director review` checks an edit's structure against what hit videos of the same length do, in new `RETENTION` lines: talking too late (an intro card or warm-up before the first word), a vertical video with nothing on its first frame saying what it is, a static screen with nothing new for too long, cutting away from the screen right after a click or typing, running on after the last word, and missing or overlong chapters from 5 minutes up. The limits come from measuring 31 hit videos at five lengths (60 s, 3, 5, 20 and 60 minutes), and vertical video and each social clip are checked by the 60 s rules. `director review <dir> --retention` prints only these.
- The Claude box knows the retention lines and acts on all of them when you ask for a full or retention pass.
- In this repo, `/retention-pass <project>` checks a video's opening, re-hooks, ending, chapters and asks against the same research, writes `.checks/retention.md` with output timestamps and a fix for each, and makes the fixes you approve, including a cold open built with `director repeat` or `move`. After each plan.json edit, Claude Code also gets the retention lines as a note that doesn't block. The research and its sources are in `.claude/skills/edit-screencast/references/engagement/`.

### Animations
- A Sticker Note's crayon mark never runs through its text: the line under the word, the word beside it and the logo above move out of the scribble's way (a squiggle under a long word crossed the line under it), and `director animate` and `animate-test` warn about any sticker whose mark crosses its text.
- The Lottie template comes with 19 overlays of its own: hand-drawn marks that draw themselves on (circle, underline, box, four arrows, check, X, a ta-da burst), pop-ins (heart, star, !, ?), confetti and loops (sparkle, click ripple, spinner, pulse), in hot pink with a black shadow so they read over the screen. They draw in like joekarlsson.com's scribbles (its pen curves, a mark's strokes one after another), and every Lottie boils like the site's marks, its outline wobbling through three frames six times a second. In the app, a Lottie animation starts over the video, picks its file from a list (with what each is for and how long it plays) or imports one, and any animation can be switched to float over the video. Agents list them with `director lottie <dir> list` and add their own with `director lottie <dir> add`. A Lottie file can say it plays once with a top-level `"loop": false`.
- `director capture <dir> <url>` pulls a website's logo into the video's animation logos (named so an animation can use it), saves a screenshot of the page into broll/ and prints the site's theme color, so explainers use the real logo instead of a drawn one. It warns when the logo is white (made for a dark header), which wouldn't show on a white sticker.
- Two new animation templates, adapted from HyperFrames' catalog: Chart (bars rise one by one or a line draws through its points as you talk, then one value gets the accent and a tag counting up to it), drawn in the paper, zine and terminal looks.
- Stickers (meme GIFs and sticker animations) move out of the captions' way: one placed over them sits just above them instead, or below when there's no room above.
- Pop-ups over the video are stickers, all alike: an animation with `sticker` ({x, y, w}) shows as a sticker exactly like a meme GIF (white border, slight tilt, the springy stick-on and shrink-away, kept inside the frame), its clip cut to the card's own size. The new Sticker Note template is the usual one: a big word or number with your look's crayon scribble drawing itself around it once it lands, a word beside it, a line under it, an optional logo.
- A new Lottie template plays a Lottie animation (an After Effects export, e.g. from LottieFiles) frame-exact in the video, over it as an overlay or on the paper: put the .json in the video's `animations/lottie/` folder and name it in the animation's data. Templates can also animate with CSS keyframes or web animations, which now render frame-exact.
- `director animate` and `animate-test` warn when an animation's text is hard to read: WCAG contrast under 4.5:1 (3:1 for large text) against what's behind it, or, in an overlay, text sitting straight on the video with no card behind it, once it stays that way for a second.
- Overlays keep out of the captions' way and inside the frame: `director animate` warns when a piece of a vertical video's overlay reaches into where the captions sit (or wherever they were dragged), or runs off the edge of the frame. In an overlay the storyboard puts nodes exactly where their x and y say instead of reframing the board around them.
- In an overlay, headings, hand-written labels and tally rows get the look's paper behind them so they read over the video, and the Lottie template places itself by shares of the whole frame, a vertical one included.
- Animations can float over the whole video instead of filling the frame: `"overlay": true` renders one on a transparent background (HEVC with alpha), and it plays over the screen recording and the face camera, under captions. In a vertical video it covers the whole frame without splitting it. B-roll can do the same with `"placement": "overlay"` for a picture or clip with alpha.
- Meme stickers: B-roll with `"placement": "sticker"` shows a reaction GIF or short clip in a white sticker border with a soft shadow over everything, placed with `x`, `y` and `w`, with optional meme text along its top and bottom (`topText`, `bottomText`) in outlined capitals. It sits tilted a few degrees like a sticker slapped on by hand (`rotation` changes the angle), springs on from nothing with an overshoot and shrinks away at the end (the new `stick` motion). `/edit-screencast` suggests 3 to 5 meme moments from the transcript when you ask for memes, or on a personal video, and adds the ones you pick.
- The camera in paper and zine animations drifts smoothly like a handheld shot, instead of jittering 12 times a second. Existing animations re-render with it the next time their video builds.
- A storyboard card or sticker casts its shadow from the air as it slams in, wider and softer, and the shadow tucks in under it as it lands, so pieces read as paper dropped on the page. Paper collage look only; existing animations re-render with it the next time their video builds.
- `director animate` and `animate-test` warn when two pieces (stickers, cards, labels, tags, rows, the heading) overlap on any frame, mid-move included, or when one reaches into the caption band, with when and for how long.
- Animations have real motion blur: stickers, cards and labels streak in the direction they pop in, while everything standing still stays sharp. It replaces the soft blur pop-ins used to fade in with.
- In a vertical video, the split for an animation eases in over about a second from the moment the animation starts (and out as it ends), instead of snapping the face to the bottom half and showing the screen recording in the top card for a moment first.
- Storyboard nodes stay alive once they land: they float, pop and brighten when a packet reaches them, and shrink and dim for a moment while a newer node takes the focus. Lines stop at a node's edge instead of running under cards or through text labels.
- Storyboard diagrams come alive: the heading rises a word at a time, each node slams in with a scribble burst behind it, nodes can have hand-drawn icons that draw themselves (`icon`: laptop, camera, mic, server, database and more), packets run along the lines, and the camera starts close on the first node and pulls back as each new one appears. Videos keep the storyboard they were made with until you choose Update Template.
- The storyboard camera zooms at a steady rate as it pulls back for each new node, instead of starting slow and rushing the end of the move.
- `director animate` and `animate-test` warn when something in an animation shows for a single frame and is gone the next (a sticker drawn a frame before its cue), with the source time to look at.
- The zine look's lines are drawn in colored pencil (p5.brush), with the uneven pressure and broken edge of a real pencil, instead of an even crayon texture.
- Stickers and cards pop in on a spring: they overshoot about 9% instead of 20% and settle smoothly, and lines, highlights and counters ease in and out instead of starting at full speed. Existing animations re-render with it the next time their video builds, and frames that move take longer to render.
- An animation can keep other versions (`alternates`). `director animate-variants <dir> <index>` renders each one in full with a sheet comparing them row by row, and `director animate-choose <dir> <index> <k>` plays the one you pick while keeping the one it replaced.

### Privacy
- `director secrets <dir>` reads what the edit keeps for API keys, tokens, passwords in connection strings and config, private keys and email addresses, and `--blur` covers each one the edit shows with a blur that cuts in and out with no fade. Until they're covered, `director describe` and `validate` warn about them, and about any stretch put back into the edit since the scan; `--allow <n>` marks one as fine to show, `--allow email` every email. It reads only the parts the edit keeps, and only where the screen changed, so 10 minutes of edit take about a minute however much footage was imported.

### Exports
- Exports and GIFs go in the recording's publish/ folder, beside the captions, chapters, description and thumbnails, so everything you post is in one place (`sd render` and `director render` and `gif` too). Exports from before stay where they are and still count for the library's badge and thumbnail.
- Every export carries what made it: the app version, the date and the exact plan it rendered, inside the MP4. `director provenance <video>` prints them and what `plan.json` has changed since, and `--plan` prints the plan, so you can tell which edit an upload was.

### Motion
- Zoom moves take as long as the distance they cover: a small nudge is quicker and a big zoom with a long pan takes a little longer, while a 1x to 2x zoom takes the same time as before. Every move into a zoom finishes at the same moment, however long it is, so longer moves start earlier rather than arriving late. A zoom with its own `seconds` keeps them.
- In vertical and square videos the camera pans to a click and parks on it before the click lands, instead of moving through the press.

### Editing
- Everything else on the video moves and sizes in the preview too: drag a box, highlight, arrow, spotlight or blur to move it (it follows zooms) and its corner to resize it; drag a title or lower third anywhere and its corner to make it bigger or smaller (agents set a callout's `x`, `y` and `size`); drag the logo watermark to another corner and its corner to size it; and the captions and camera bubble, which already dragged, get a corner knob to size them. Hover over anything to see its box; click an annotation or title to select it.
- Move, resize and rotate stickers and overlays right in the preview: drag a sticker to move it, click it to select it, then drag its bottom-right knob to resize it or its top-right knob to rotate it (it snaps straight within 3 degrees). Overlays (a Lottie or any animation over the video, or a picture with alpha) select from the timeline and get the same handles; they can now be placed, scaled and turned anywhere instead of always filling the frame, with no re-render. Agents set the same thing with an overlay animation's `place` {x, y, w, rotation} or an overlay insert's `x`, `y`, `w` and `rotation`.
- `director faces <dir>` finds your face under each sticker, sticker animation and title (rendered a moment after it lands, in its middle and just before it leaves) and says how much of it each covers, with a clear spot to move it to, off your face, the captions and the apps' buttons; `director review` lists each one covering more than a tenth of your face.
- Pop-ups and titles stay up long enough to read: `describe` warns, and `director validate` fails, on any callout, meme or picture sticker, sticker animation (like a note) or overlay animation that's on screen under 3 s of the output, or under 0.3 s a word plus half a second when it has more to read. Review's reading-time note now covers only box and arrow labels.
- Voice effects: put a comic effect on your own voice for a word or phrase (chipmunk, deep, echo, cathedral, radio, phone, robot, alien, reverse, tape stop, slow-mo, bleep) by asking Claude or adding `voiceEffects` to plan.json. They're built from Apple's audio units, match your voice's loudness and stay in sync with your lips.
- Cut pauses keep a breath where a sentence ends: about 0.45 s between sentences and 0.7 s when you pause longer to move on to a new thought (at the normal pause level; gentle keeps more, tight less), with the breath after your last word. Pauses in the middle of a sentence are cut as tight as before, so the rhythm sounds like you rather than a string of jump cuts. New drafts and `director pauses` use it.

### Fixes
- YouTube chapters come from your chapter titles only (or from your titles, when a video has no chapter titles), so a lower third like "Try it free" or a one-off title no longer shows up as a chapter.
- A transition of 0 switches between full camera and the split as a hard cut: it used to leave one half-way frame at each switch, which showed as a flash.
- On macOS 26 the scribble burst behind a storyboard node erases instead of flashing back for a frame, and the zine look's marks erase the same way.
- B-roll shot on a phone held sideways or upside down plays upright, instead of turned 90° and cropped.
- A layout that runs to the end of the video holds through the last frame, instead of easing back to the default layout (and showing the screen) in the last half second.

### CLI and agents
- `director stock <dir> videos <query>` finds free video B-roll on NASA, Wikimedia Commons and the Internet Archive's Prelinger films, and `stock <dir> gifs <query>` finds GIFs: openly licensed ones on Openverse, plus KLIPY reaction GIFs in personal videos only (work videos never get them). Each user pastes their own free KLIPY key in Settings > Stock (kept in the Keychain), or sets `KLIPY_API_KEY`. `get-video` and `get-gif` download into `broll/` as MP4s that play in the edit, with GIFs looped, and log each license in `broll/stock-licenses.csv`. The app's Claude box can search and download them too.
- `director check-words <dir> <export.mp4>` transcribes a finished video and compares it with the words the edit keeps: a word clipped at a cut, or a false start left in at one, is listed with its time. A word Whisper merely hears differently isn't.
- `director scan` also finds hitches in a finished video (a frame that repeats while the picture moves, which a camera recording at 25 fps in a 30 fps video does every sixth frame) and black frames mid-video. Animations stepping at 12 fps on purpose don't count.
- `director review` names a camera whose frame rate doesn't divide into the video's (a 25 fps PAL camera in a 30 fps video judders on your face), with the fix.
- `director review` adds polish notes: a click that lands while the camera is still moving, camera moves too fast for the video's motion style, a camera that stops and starts or doubles back, titles and labels too short to read, styled transitions on too many cuts (or the same one twice in a row), more than three sound effects in ten seconds, and two overlays entering on the same frame. The edit skills and the app's Claude box fix them.
- `director animate-test <dir> <index> <source-second>` renders one second of an animation from that moment, with a contact sheet of its frames, so a new template's hardest move can be checked in seconds before the whole animation renders.
- `director contact-sheet <dir> <out.png>` puts a labeled frame from each cut, zoom, layout, title, B-roll, punch-in and animation beat into one image, to check a whole edit before rendering it. Claude Code's edit and animate skills look at it first.
- Everything the app does can now be done from the terminal or by an agent ([docs/cli.md](docs/cli.md) maps each app action to its command).
  - `director draft` (and `sd draft`) makes the same first draft as the app: the plan, then your default profile, pause level and voice polish, face centering and lip sync. `sd auto` now uses it.
  - `director profiles` lists your profiles. `director profile` takes a saved profile's name as well as a folder, and `profile-save` saves a video's look.
  - `director template` freezes, updates or saves an animation template.
  - `director add` copies B-roll, a LUT (checked first), music, a logo or a font into a project.
  - `director settings` reads and changes the app's settings.
  - `director upload` uses the bucket from Settings › Sharing when no `S3_*` variables are set.
  - `director validate` checks `plan.json` after a hand edit and lists each problem with its JSON path. It catches keys that aren't plan fields (a typo like `"styl"` used to do nothing, silently), positions off the screen, overlapping segments, unknown styles, eases, templates and effects, missing files, titles, zooms and B-roll on screen under a second, and every warning `describe` prints. `bin/director` runs it (and every other command), rebuilding first when the sources changed.
  - `director status` shows what the recorder is doing, and `--wait ready` blocks until a new recording is saved, drafted and named.
- The app picks up settings changed by `director settings set` when it comes to the front, so it no longer needs a restart.
- The Claude box can apply a saved profile ("use my CData look"), freeze or update an animation template, and runs `validate` on its own edits. Every command it runs is held to the open project.
- In this repo, Claude Code runs `director validate` after every plan.json edit and fixes what it finds.
- When a Claude box ask leaves a new problem in the plan, its reply lists it. Follow-up asks continue the same conversation, so "a bit tighter" knows what the last ask did. It also knows about voice settings, effects, intro and outro cards, the look, the cursor and cover moments, which it couldn't edit before.
- The Claude box cuts, restores, moves and repeats stretches with the same commands as the CLI, and re-cuts the pauses ("tighten the pauses"), so a cold open keeps its zooms, titles and captions with it.
- `macos/app-shot.sh` screenshots the editor on a copy of a recording, for checking a UI change without touching the real project.
- `screencastdirector://` links drive recording in the running app (`record/start`, `stop`, `pause`, `resume`, `restart`, `discard`, `retake`) and open a recording (`open?project=<folder>`).
- Rendering an animation from the CLI while the app has the same video open no longer breaks either render. Each one cleaned up the other's in-progress file, and the app could hang.

### Sound and music
- Background music can drop out for a stretch, e.g. while code or terminal output is on screen: `music.off` lists source-time ranges ({start, end, note?}) where the music fades out over the 0.3 s before and back in over the 0.6 s after, the same ramps as ducking. A range in a cut part does nothing. `describe` lists each with its output time (or CUT), `director validate` flags one that ends before it starts or lies outside the recording, and the Claude box adds them when you or the edit plan ask for music off. Profiles leave them out, and applying one keeps the video's.
- `director stock` searches Openverse for sound effects (under 30 seconds, mostly Freesound) and pictures (Wikimedia, Flickr and others), CC0 and public domain only unless you add `--credit-ok` for CC BY. Downloaded sounds show up in the sound picker under Openverse; pictures go into the video's `broll/`. Each one's license and credit line is saved in `openverse-licenses.csv` next to it, for a Content ID dispute or the description.
- Work-only sounds and music: files in `Work/Sounds` and `Work/Music` (in the support folder) are listed, and can be built into a video, only when its profile has `"work": true` in its profile.json. A video with another profile that uses one fails `director validate` and won't render. Applying a profile now records its name in the plan as `profile`.

### Recording
- The camera records at the best size it offers, up to 4K at 30 fps, with the bitrate to match (40 Mbps at 4K). It used to be held to 1080p whatever the camera could do. Recorded B-roll from a camera too.
- Record B-roll into the open video (File > Record B-roll…, or hold the B-roll button): a small panel with a live preview records a clip from the camera or the screen into its broll/ folder, then shows it full frame from the playhead for the clip's length. One undo takes it off.
- A floating recording widget: clock, mic level, camera preview, retake count, and Pause, Restart, Discard and Stop. It never shows up in the recording.
- Pause while recording. The paused stretch is cut from the draft.
- A 3-2-1 countdown before recording starts (Settings > Recording; ⌃⌥⌘R during it cancels).
- New Recording (⌘N) picks the display or window, the mic and the camera before you start. ⌃⌥⌘R still records right away.
- New Recording shows a live camera preview and a mic level meter, and reads the camera's white balance: whether the picture runs warm, cool, green or magenta, what to change for neutral, and the camera Warmth that would neutralize it in the edit.
- New Recording says "No sound" when the mic has heard nothing for 3 seconds (muted or dead mic), and says when it's waiting on the macOS camera or microphone prompt.
- The Camera pickers show the camera a recording will actually use when the saved one isn't plugged in, instead of going blank.
- Record any connected display, not just the main one.
- The recording widget floats above full-screen apps and other floating windows, and the arrow on its right shrinks it to just the clock and Stop.
- If the recording stops on its own (mic unplugged, window closed), what was recorded is saved and the app says why. Before, the app kept acting as if it were still recording.
- `sd plan` (and `director plan`) on a recording that hasn't been analyzed says to run `sd analyze` first, instead of writing a draft that cuts the whole video.
- `sd record`, `sd devices` and the standalone input logger are gone: the app records. `sd` rebuilds `director` when its sources change instead of running a stale build, and passes every argument through to it.

### App
- The home screen lists Recent Projects: your recordings plus any project you opened from another folder (one made with `sd import` or `director join`), so a project made outside the app no longer disappears after you close it. The sidebar and search list them too. Each card shows a frame from your newest export (the recording before you export), and hovering it plays a short montage of moments from across the video.
- Vertical covers from Publish are laid out like a real Reels cover when the video has B-roll: a sharp frame of the B-roll on the top half, you on the bottom framed with headroom and zoomed so your face reads, and the title on one accent bar across the seam, with the site's crayon marks (asterisk, burst, rays, a double underline and a coil) on zine-look covers. Covers no longer pick moments hidden under B-roll, faces cut off by the frame's edge or turned away, and the face is framed by its height too, so the top of your head isn't cropped off.
- The camera's room can be redrawn as halftone (Camera › Room, `camera.room: "halftone"`): the room behind you in the accent's halftone dots on black, like the photos on joekarlsson.com, while you stay in full color. **Crayon outline** (`camera.outline`) traces a chalk crayon line around you that wobbles. Both use the person segmentation the cutout uses.
- B-roll matches the halftone room: a video clip's background goes to halftone dots with its subject (your hand and the device, found by Vision the way Photos lifts a subject) in color and the crayon outline around it. Video B-roll follows the camera's room; set `room` on an insert to "halftone" for a picture or "none" to keep a clip as shot. Covers made by Publish get the halftone room and outline too, graded like the video's camera.
- Covers in the zine look (Pink Scribble) get joekarlsson.com's crayon marks: rays bursting off the title's chip, an asterisk and a starburst by the title, and a chalk coil along the photo's top edge.
- The halftone room's edge holds steadier: each frame's person mask is averaged with the two before it in the same clip (never across a cut or in a sped-up stretch), so hair and fast hands flicker less.
- Save as Profile keeps the camera's room and crayon outline.
- Big type chapters (Chapters › Style, `look.chapterStyle: "big"`): a black band, only as tall as its words, rises with the chapter in big centered letters, its label in a chip on the band's edge, and crayon rays and a coil from joekarlsson.com drawing in. In a vertical video it sits on top of the camera, clear of your face, and keeps inside the area TikTok, Reels and Shorts don't cover. A long word shrinks to fit rather than wrapping. Captions step aside while it shows.
- A zine theme for animations (`look.animationTheme: "zine"`), after joekarlsson.com: a black stage, Anton headings in capitals, hot pink cards and dots with black type, paper-white stickers and tags, the heading's highlighted words in pink, squiggly lines and highlight rings drawn in crayon, and the site's own scribbles (a coil, bursts, tallies, an X) drifting dimly behind, drawing in and erasing on slow loops and wobbling like hand-drawn lines.
- More › Check Edit lists cuts that clip a word and shots too short to read, and jumps to the first. A clip's Order section can repeat it at the playhead, not only as a cold open. Animation beats can each play a sound from the library. Import Video can bring a camera video of the same take, lined up with your voice during analysis.
- Problems that used to fail quietly now say so: a plan version that can't be kept in .history, an animation template whose manifest can't be read (listed in the Animate menu), a broken logos.json (the render names it), and a look color that isn't #rrggbb (`describe` warns; it used to draw black).
- Zooms, punch-ins, layouts, B-roll, animations and effect ranges have a Label field in the inspector; it's what their timeline bar shows. Camera › Split screen can join a padded side-by-side layout into one card.
- Make social clips in the editor: with an in/out range marked, the clip button on the timeline adds a vertical clip of it, and Format › Clips names it and sets its format, hook title, pause level and logo. Export them from the Export menu as before.
- Background & Frame › Effects adds, sets and removes effects for the whole video. Save as Profile keeps the video's effects and default layout, and can include its music, voice settings and camera color and bubble.
- Branding in the editor: Background & Frame sets the frame style (plain, brackets or window), the accent color, a logo (corner, size, opacity), title and chip fonts and colors, the camera border color, font files of your own, and the animation theme. Intro and outro cards can have their own logo.
- Camera punch-ins in the editor: the viewfinder button on the timeline punches in on the camera over the in/out range or for 1.5 s from the playhead. Each one is a bar on a Punch-in row (drag, trim, ⌫), with its scale and aim in the inspector.
- Upload and Copy Link is grayed out until a bucket is set up in Settings › Sharing, and Publish only offers camera covers when the recording has a camera.
- A tidier inspector. Camera: Split screen comes first, Bubble starts folded when no layout shows the bubble, Lip sync starts folded, the color sliders sit under Fine-tune, and a cutout hides the shape, border and shadow it doesn't use. With no camera the tab only says so. Captions off hides the caption settings, a hidden cursor hides its size and smoothing, Chapters shows once there are two chapter cards, and Shortcut labels moved into Cursor. Music is one row (library or your own file), and a title's or mark's sound can come from the sound library.
- The timeline hides empty rows: the ruler, clips and audio always show, words with a transcript, and Zoom, Layout, Titles, Marks, B-roll, Animations, Effects and Sound FX only once they have something on them. The Effect menu says when no effects are installed and opens the Effects folder.
- Plans with missing fields load: one from before plan versions, or one written by hand without `callouts`, `clickRipples` or `style`, used to fail to open. Missing fields take the defaults a new video gets.
- Settings › AI keeps the Test Connection result when the window redraws, and the button is off when Claude Code isn't installed. Publish's Copy says why when it can't read a file instead of copying nothing.
- Preview volume: a speaker button and slider under the preview set how loud it plays while you edit (click the speaker to mute). The export keeps the video's own levels.
- B-roll's In and Out menus show the real default, a cut, instead of Fade. Background & Frame › Motion › B-roll sets how every B-roll and animation without its own motion comes and goes (`style.brollMotion`).
- The terminal animation theme moves: a slow camera drift with the odd VHS sync slip, lines that jitter like a CRT signal, packets running along every line, and a flickering, rolling scanline layer.
- Vertical videos keep every title, chip, caption and the logo clear of TikTok's, Reels' and Shorts' own UI (the top 12%, bottom 22% and right 12%), and animations lay out below the top band. Step chips used to sit right under the apps' tabs.
- A terminal theme for animations (`look.animationTheme: "terminal"`): a 90s screen with square DOS-style boxes, hard shadows, mono type, inverse-video highlights, right-angle lines, flicker-on entrances and a blinking cursor, instead of the paper collage.
- Animations re-render when the look's accent, fonts or theme change; before, a new profile kept the old clips.
- Intro and outro cards take the video's effects, so they match the rest of it.
- B-roll and animations can come in and go out like an interlaced TV picture (the `interlace` enter/exit), and `style.brollMotion` sets how B-roll without its own motion comes and goes, so a profile can give every video the same B-roll transition.
- Effects for a stretch: the wand button on the timeline turns an installed effect on over the in/out range or for 5 s from the playhead. It gets a bar on a new Effects row (drag to move or trim, ⌫ to remove) and its own settings in the inspector, from the effect's params. In the plan it's `effectRanges`.
- Effects can follow things: an effect that asks for tracking gets boxes around what Vision finds on the camera (the face, each hand, the person, something held up; found once and kept in `tracking.json`) with what each is and how sure Vision is, or the pointer and recent clicks on the screen. Boxes mostly out of view of a zoomed camera are left out. Camera effects now draw after the camera is mirrored, so their text reads the right way round.
- Effects get `cutKind`: whether the nearest change is a cut, a jump back from a cold open, B-roll, a layout change, a punch-in or a new section, so an effect can save its big moments for the ones that matter.
- A camera enlarged to fill the frame (a 1080p camera in a vertical 4K video) is scaled with Lanczos instead of a plain resize, with a light sharpen, so it's less soft and blocky.
- Effects: shader plugins that draw on the screen, the camera or the whole frame, under titles and captions. They react to clicks, cuts and clip speed. Install one in the Effects folder and list it in the plan's or profile's `effects` ([docs/effects.md](docs/effects.md)). None ship with the app.
- A punch-in can move the camera's framing point (`x`, `y`) and widen (`scale` below 1), to cut to something held up beside your face that a vertical crop would cut off.
- Captions: drag them anywhere in the preview, and set their text, highlight and box colors, box opacity, font and size in Cursor & Overlays > Captions. Bold and social captions can have a box behind the words (`captions.box`, `x`, `y`, `size`).
- Reorder clips: play any part of the recording first (a cold open) or anywhere else. Select a clip and use Order > First, Earlier, Later, Last, or `director move <dir> <start> <end> [--before <t>]`. Its zooms, titles, captions, B-roll and sounds move with it. Older videos keep playing in recording order.
- Space at the end of the video plays it again from the start.
- The caption controls fit the inspector: Style is a menu, and the color swatches sit in one row.
- Caption emphasis: words or phrases you list (Captions > Emphasis) draw bigger in their own color wherever they're said.
- Vertical step chips can list the earlier steps under them, ticked, like a checklist (Cursor & Overlays > Chapters).
- Storyboard animations draw their stickers and labels bigger in a vertical video's square card.
- Big vertical captions shrink a word too wide for the frame ("CUSTOMIZABILITY") instead of breaking it across two lines.
- Camera > Mirror flips a camera that records mirrored, so a page or device you hold up reads the right way (`camera.mirror`).
- Recordings sort by when you last opened them (Recently Opened, the new default), and the menu bar's Recent list shows the ones you opened last instead of the newest.
- Plan the edit in the script. An `## Edit plan` in the header of the Followspot script you record with (zooms, annotations, callouts, animations, sound effects, punch-ins, layouts, each tied to the words you say) shows up in `describe`, and Claude applies it when it edits.
- Space plays and pauses even after you've sent a Claude edit (the box keeps focus but is empty), and clicking the preview or timeline takes focus out of a text field so the shortcuts work again.
- Zooming the timeline (slider, pinch, ⌥-scroll, ⌘= / ⌘-) keeps the playhead where it is, and centers it if it was scrolled out of view, instead of drifting ahead while you drag the slider.
- An AI edit no longer shows "Claude is editing…" forever. Each reply goes to the request it answers, an edit that fails says why (Claude Code's own error, like being signed out), and one that finishes silently says so. Quitting the app stops a Claude edit still running instead of leaving it changing your plan in the background. Old edits stuck this way now say they didn't finish.
- Zooming the timeline all the way out shows the whole timeline, however long the video is, and it stays fitted when the window or the edit's length changes.
- When the timeline is zoomed out too far to read words, the Words row marks where you speak instead of going blank.
- The timeline starts in output time, so cuts close up and sped-up clips draw at their real length. Clips show their frames in both modes; the toggle by Fit switches back to the whole recording.
- An unanalyzed recording shows a labeled Analyze button in the toolbar and in the inspector.
- The X on a banner is easier to hit. Before, only a click right on the X closed it.
- Move a recording to the Trash from its right-click menu in the sidebar or on Home.
- Reviewing an AI edit lists added animations, sound effects and B-roll as their own changes you can undo, and flashes them on the timeline. Before, an added animation showed up as "Style, captions and settings".
- Select All (⌘A) picks markers, B-roll, animations and sound effects too, not just zooms, layouts, titles and annotations.
- Export > GIF with a layout, B-roll or animation selected exports that stretch, instead of the whole video.
- Dragging an item on the timeline snaps to sound effects.
- The preview and export no longer re-read the camera's LUT file for every frame.
- A watermark or intro/outro logo named relative to the project now shows. Before, it was looked up from the app's working folder and silently left out.
- When Clean up voice fails, the preview plays the original voice and the banner says why, instead of silently skipping it.
- Inspector controls (the voice toggles, Pauses, Shape and Resolution) always show the current plan, not the value from when the pane was drawn.
- Add Music File opens as a sheet instead of blocking the app, copies the track into the project's music/ folder like the library does, and keeps the music's volume settings.
- `describe` warns, in a Fonts section, about a font file that can't be read and about a title, caption or chip font that isn't installed, instead of silently drawing another font.
- A recording whose motion.json or loudness.json is corrupt says so when it opens, instead of planning as if there were no motion.
- Errors that used to pass silently now show in the banner: a plan.json that can't be read (it used to look like a recording that was never analyzed), a broken profile, a key the Keychain wouldn't save, a failed AI double-check, a missing B-roll or music file (they used to drop out of the video), a failed loudness measurement (normalizing and music ducking used to switch off), and Claude's own error text when a YouTube description fails. Errors that showed as "Publish error 2" now say what went wrong.
- Claude edits can run `director describe`, `still` and `review` again. The app's path has spaces, so the quoted command Claude ran didn't match its allow rule and was blocked.
- Claude Code is found when it is installed in ~/.local/bin and only .zshrc adds that folder to PATH. Before, the app said Claude Code wasn't installed.
- Renaming a recording while it's analyzing or exporting waits until it's done, then renames it, even if you've clicked away to another recording. Before, the rename broke the analysis with "The folder motion.json doesn't exist".
- Getting Started plays a short demo in place of the 3-minute tour.
- A new look: the app's indigo accent throughout, and a refreshed icon in the layered glass style.
- The start page is a gallery of your recordings with a big New Recording button. Setup folds away once everything's ready, and first-timers see how it works.
- Opening a recording shows a blurred poster with "Loading preview…" instead of a black box.
- The export button shows a progress ring while exports run.
- Smoother transitions when switching recordings and showing or hiding the inspector.
- Badges stay readable on a selected sidebar row.
- A menu bar menu: start, pause, retake, restart or discard a recording, pick the display, mic and camera, and open recent recordings.
- Standard Mac menus and windows: About, Hide, the Window menu, Show/Hide Inspector (⌥⌘I), and Settings split into General, Recording, AI and Sharing tabs.
- The editor's buttons move to the window toolbar; the project's name and length are in the title.
- The preview matches the export's shape (vertical, square) on a dark stage, with play, step and a scrubber under it.
- Sort the library by recently added (the default), oldest first, recently edited, name or length, from the Recordings header or View > Sort Recordings By.
- The library shows a poster frame, length, date and a New or Exported badge. Double-click a name to rename it in place.
- Errors and confirmations show as banners in the window instead of dialogs that block the app.
- Ask Claude: a new prompt box with starter ideas and a history of what you asked and what it changed.
- Ask Claude shows each step as it works (reading the timeline, checking frame 412, editing the plan) and has a Stop button.
- After an AI edit, a list of what it changed: jump to each change, undo just that one, or keep them all.
- The AI knows your playhead, selected item and selected transcript words, so "zoom here" and "cut this" work. The box shows which AI answers, with a Set Up link when it isn't ready.
- The AI knows what you clicked: analysis reads the text around each click on screen (on-device, with Apple's Vision), so the timeline says `click on "Settings…"` and zooms say what they're aimed at. Older recordings get it before their first AI edit, or with `director screentext`.
- With a script, the timeline lists script lines the edit is missing (never said, or every take cut), so the AI can restore a take or tell you.
- New starter ideas in the Ask box: chapter cards, a lower third with your name, boxing what you click, blurring emails and keys, a cinematic feel.
- What you asked is kept with the recording, so the history is still there after switching recordings.

### Editing
- First drafts have no blink-length clips: a clip under a second that plays straight into the next one, like the bit of pause kept at a cut, joins that clip, so a draft no longer opens with a flash. Speech is never folded into a sped-up clip.
- Drag a clip on the timeline to reorder it: a white line shows where it will land, and it plays there when you let go (output-time view; in the recording-order view clips stay put). ⌥⌘← and ⌥⌘→ play the selected clip earlier or later.
- Publish > Use Playhead Frame for a Cover: pick up to three moments for the covers (saved in the plan as `coverAt`), instead of the clearest faces. Landscape thumbnails match the vertical covers: the title big on the dark left, you framed on the right. Thumbnails show at their own shape in Publish.
- Repeat a clip: play a moment again as a cold open while it stays in its place too (Order > Repeat as Cold Open, or `director repeat <dir> <start> <end> [--before <t>]`). Zooms, punch-ins, B-roll and captions play in both showings, titles and sounds only in the original.
- After an export finishes, the app scans the video itself for shots under a second (a sliver of a punch-in, a frame of B-roll) and banners the first with a button to jump to it. `director scan <video.mp4>` runs the same check.
- Exports end in their resolution: "Name 2160x3840.mp4", "Name - Hook 1080x1920.mp4".
- Punch-ins can't leave a sliver of the wide shot: one ending (or starting) within a second of its clip's cut runs to the cut. The flash check now also catches short punch-ins and quick cuts between two clips of your face.
- No fades nobody asked for: B-roll and animations cut in and out hard unless they set a motion, the voice ramps for 12 ms at each cut (it was 100 ms, which clipped words), and music starts and stops with a 0.15 s ramp instead of fading in over a second and out over two.
- Publish makes vertical covers for a vertical video: the title big on the profile's dark color with the last word on the accent chip, over a camera frame framed on the face. `director publish --at 4.8,85` makes them from moments you pick (like holding the product up). Thumbnails now follow the camera's Mirror setting.
- Flash warnings: anything on screen for under a second between two other things (the face between two B-roll clips, a layout switching away and back, a clip too short to register) shows in a banner with a Show button, and as a WARNING in `describe` and `review`.
- **Fill the frame** (Background & Frame, at 0% padding): the screen is cropped to fill a 16:9, square or feed frame, so no background shows around a screen of another shape. It pans to follow zooms and clicks.
- A profile can frame the screen and camera as windows (`look.frame: "window"`: a dark title bar with three dots over each padded card, including a square camera), and join side by side into one card with no gap (`style.joinSide`).
- Clips: name a stretch of the edit and a format (vertical for Shorts, Reels and TikTok, square, feed) and export it from Export > Clips, alone or all at once. Clips render from the main edit, so a fix there shows up in every clip, with no copied projects. Claude can add them too.
- Clips go out ready to post: a clip can run tighter than the main edit (`pace`, re-cut from the measured silences, never inside an animation), its captions file is written beside it, a clip that opens partway into an animation leaves it out, and vertical keeps its logo, titles and captions clear of the TikTok and Reels tabs and buttons.
- An animation whose start is cut picks up where the edit does, instead of playing from its beginning out of step with the words.
- Exports are named after the project (Connect AI and Dots.mp4, Connect AI and Dots (4K).mp4, Connect AI and Dots - Hook.mp4) instead of out.mp4.
- Vertical videos look like Shorts: you fill the frame when you talk to the lens, and the screen goes in a square card on ink with you full width under it and an accent seam between. Captions are big, bold and a few words at a time on the seam, chapter titles become step chips on the screen card, and animations play in the card with a layout of their own shape (storyboard, and any template that sets `reflows`). A clip can open on a hook title and carry a logo at the top.
- Lip sync no longer sets the camera about 80 ms early. Lips open a little before the sound comes out, and the measurement now allows for it: in-sync footage measures within 20 ms of in sync, where it used to read 60-96 ms early. Run Camera > Lip sync again on videos synced before this.
- An intro or outro card written into plan.json or a profile without `"enabled"` now shows. Before, it was silently left off; `"enabled": false` still switches one off.
- Saving an unchanged plan no longer adds a copy to its history. plan.json now keeps its keys in a fixed order, so a save that changes nothing writes the same file, and the 30 saved versions are real edits.
- Times just under ten seconds or a minute read correctly in the timeline description and the editor's status line (59.97 s was "0:60.0", 9.97 s was "0:010.0").
- Screen motion is measured every 0.1 s as intended. Rounding skipped about one sample in seven, so short bursts of screen activity could be missed when the draft decided what to speed up.
- Animations: Vox-style explainers with real app logos, stickers that pop in, hand-drawn lines and highlighter, timed to what you say. Two templates to start (One at a Time: wiring apps up one by one until it's a mess; One Hub: one connection that fans out to all of them). Add one with the ✦ button over your in/out range, the selected words, or from the playhead. Edit its heading, logos, apps and labels in the inspector, and set each beat to the playhead, or press Fill In From What I Say and Claude writes it from your words. They have their own Animations row on the timeline, render by themselves when you change them, and move with their beats when you drag them.
- Storyboard animations: build any diagram step by step, each step on a word. Show a logo, dot, card or label, connect them, add a note, count something up, highlight, dim or hide, tangle the lines, circle the board, or clear to a new board. Steps are edited in the inspector.
- Each video keeps its own copy of the animation templates it uses, so changing a template later never changes a finished video. Update Template takes the latest on purpose; Save to My Templates puts a video's version in your library (~/Library/Application Support/Screencast Director/Animations) for other videos. Templates and logos made for one video live in its animations folder.
- Camera > Bubble adjusts the camera bubble while you demo: drag it anywhere in the preview, or set its size, position (or snap it to a corner), shape (circle, rounded, square), border and shadow.
- Cut out background: show just you over the screen, with no circle, using on-device person segmentation. In a bottom corner the cutout stands on the frame's edge.
- The background cutout shows your whole upper body. Before, the bubble's square edges and the camera zoom sliced off your shoulders and arms.
- The background cutout only applies to the camera bubble over your screen. Full-camera stretches keep your room behind you, and it fades back in as the camera grows to full screen.
- Chapter cards darken the video behind them more, so the title reads over a busy screen.
- The camera stays in sync with your voice. After a recording, the app compares your lips with the audio and lines the camera up. Some webcams deliver frames late, which put the camera a third of a second behind. Camera > Lip sync has a slider to adjust it by hand and a Sync to My Voice button; the CLI has `director sync-camera`.
- Camera punch-ins (`camera.punchIns` in the plan): the camera snaps tighter on your face for a beat, then snaps back, for punctuation on a key line.
- Pause trimming drops clips stranded between cuts: anything under a second, or under two seconds and mostly silence. The cut runs on to where you start talking again, instead of flickering through a stray word or a sliver of silence.
- In a narrated recording, the draft cuts silent scrolling and pointing longer than 3 seconds instead of keeping it at 1.5x. Shorter moves, and recordings with no narration, still play at 1.5x.
- Playback no longer redraws the whole editor 30 times a second; only the playhead, clock and current transcript word follow it.
- A Claude Code edit is one undo step, however many times it saved the plan, and timeline edits wait until it finishes.
- Dragging a slider saves the plan once you pause instead of on every tick.
- Errors (a failed analysis, preview or save) show as banners, with Retry for the preview.
- ⌫ on a selected cut restores it, as its tooltip says (the toolbar button becomes Restore).
- Edit by text: the Transcript button (⌥⌘T) opens the transcript beside the preview. Drag across words (or shift-click, then ⇧←/⇧→) to select them, then Cut, Zoom, add a Title (or lower third, slate, chapter), Annotate, or Ask AI about them. Find in transcript with match counts, filler words in italics, and the spoken word stays in view while playing.
- The inspector has controls for every motion feature: motion style tiles with live easing curves, a zoom's ease and length, a title's style, second line and in/out animations, an annotation's kind, area (drag on the frame), label and animations, a clip's styled cut, and caption styles. Preview plays from just before the item.
- A Marks track for annotations, a title button that holds lower thirds, slates and chapters, and an Annotate menu (A adds a box).
- Pinch or ⌥-scroll to zoom the timeline around the pointer; the zoom slider and ⌘= / ⌘- keep the playhead in place. The timeline follows the playhead while playing, clicking an empty spot moves the playhead, and ⌥← / ⌥→ nudge the selected item a frame.
- A strip under the scrubber shows the finished video's shape: real-time clips in blue, sped-up parts in orange, titles as ticks and zooms underlined.
- Transport buttons have VoiceOver labels.
- Select several items: ⇧- or ⌘-click bars, drag a box over empty track space, or ⌘A. Drag any of them, or press ⌥← / ⌥→, to move them together; ⌫ removes them all.
- Markers: M drops one at the playhead, ; and ' jump between them, and you can name them in the inspector. The AI sees them, so "zoom in after the intro marker" works.
- In and out: I and O mark a range, then cut it, speed it up, zoom it, title it, annotate it or ask the AI about it from the timeline toolbar. ⌥X clears it.
- Output time: a timeline toggle lays the timeline out like the finished video. Cuts collapse, sped-up clips shrink to their real length, and the ruler counts output time; editing works the same.
- Clicking any empty spot on the timeline now moves the playhead (only the top strip of the tracks responded before).
- The trim cursor no longer gets stuck after deselecting a bar.
- Fixed a hang at the end of an AI edit: pipeline steps now run on the main thread, so they never update the window from the background.
- Clips on the timeline show thumbnails from the recording, and after an AI edit the parts it changed glow briefly (the timeline scrolls to them).
- The timeline has track icons, a color per track, a playhead you can drag on the ruler, and snapping to the playhead and other edges (hold ⌘ to turn it off).
- The inspector has icon tabs (Selection, Background & Frame, Camera, Audio, Cursor & Overlays, Format, Transcript), with controls grouped in cards.
- Sound effects: `sfx` in plan.json plays a whoosh, pop or ding at a moment in the recording, at full volume over the voice. Ask Claude to add them. They show on their own Sound FX row in the timeline (drag to move, ⌫ to remove, volume in the inspector), and `describe` shows where each lands (or that it's cut).
- A built-in sound effect library: 37 of the sounds YouTubers reach for (whoosh, pop, ding, boom, record scratch, airhorn, sad trombone, ba-dum-tss, crickets, ka-ching and more), all CC0 from Freesound, trimmed to hit on their mark and leveled. Add Sound Effect… in the Audio inspector lets you play each one and adds it at the playhead. Drop your own into My Sounds (~/Library/Application Support/Screencast Director/Sounds) and they show up too. Claude sees the library in `describe` and can use any of them, and a video keeps its own copy of each sound it uses.
- A built-in music library: 13 CC0 background tracks from FreePD by Kevin MacLeod, Rafael Krux and Bryan Teoh, in upbeat, tech, chill, jazz, comedy and dramatic moods, leveled to the same loudness. Music Library… in the Audio inspector plays each one and sets it as the video's music (Change Music… swaps it and keeps your volume settings). Your own tracks in My Music (~/Library/Application Support/Screencast Director/Music) show up too, Claude can pick one when you ask for music or the script's edit plan names one, and a video keeps its own copy.
- Captions skip words in sped-up stretches. Those play muted, so their words showed up on screen without being heard.
- The One Hub animation's background field of logos no longer repeats the grid's apps over and over: give it its own list (The rest) and each logo shows once.
- Normalize voice now evens out your voice phrase by phrase, the way a voice-over engineer rides the fader: trailing-off or leaning-away moments come up and loud ones come down (most of the way, so it still sounds natural), and pauses aren't pumped up.
- Warm voice (Audio tab): a deeper, fuller voice from a desk mic. More chest, less boxiness, gentle compression and a touch of saturation, at the same loudness. Settings > General > New recordings can turn Normalize and Warm voice on for every new recording.
- Attach a sound to a title, an annotation or an animation's beat (Sound in the inspector), and it plays as that thing appears and moves with it, so it can't drift away or land in a cut. `describe` warns about a free-standing sound effect that's in a cut.
- The preview always plays the latest edit. A slow rebuild of an older version could replace it, so the preview sometimes played without Normalize voice even though the export had it. If the voice processing can't be set up, the preview and export now say so instead of playing the voice unprocessed.
- A profile can set voice leveling (Normalize, Warm voice, volume), the camera's color and LUT, the bubble's size and shape, and the default layout, so applying it sets up a whole video. It changes only the settings it names.
- Camera color has Highlights and Shadows (tame a hot-lit face and lift a dark room separately), Vibrance (more color in the room without making skin orange), and a LUT: **Choose…** copies a 3D `.cube` file into the video's `luts/` folder and applies it after the other controls. Presets keep the LUT.
- The camera's Warmth grade works the right way round. Raising it made the camera bluer and lowering it made it orange, so the Warm look came out cool and the Cool look warm.
- Folders inside My Sounds and My Music show up as their own groups in Add Sound Effect… and the music picker (a `Meme` folder lists as Meme). Two files with the same name in different folders get an error naming both, since a video refers to a sound by its file name.

### Motion
- A video that opens (or ends) on the full camera starts and stays there, instead of easing in from the bubble over the first frames.
- The camera bubble's border no longer draws over a full-frame animation.
- Two parts of one animation that meet across a cut play straight through, instead of fading out and in with your face and the screen flashing between them.
- An animation or full-frame B-roll that runs to the end of the video (an end card) stays up through the last frame, instead of fading out to show the footage under it.
- Exporting in another format (4K, vertical, square, feed) renders the animations at that size first. Before, the export quietly left every animation out, and `director render --preset` did the same.
- Animations in a vertical, square or feed video show the whole board at its true shape, centered, instead of stretched to fill the frame.
- The cursor, click ripples, shortcut chips and annotations no longer draw over a full-frame animation.
- A B-roll or animation clip a little shorter than its slot holds its last frame, instead of flashing its first frame at the end.
- `describe` warns when the full-camera layout hides clicks or typing, so a demo can't end up behind your face.
- Motion styles (Smooth, Snappy, Cinematic, Bouncy) set how every move in the video eases: zooms, layout changes, and how titles and other overlays come and go. Classic keeps the old look.
- Zooms ease along real curves (or springs), change scale evenly and keep the point they zoom toward still on screen, so a zoom into a corner no longer swings out and back. Each zoom can pick its own ease and speed.
- Titles, shortcut chips and captions animate in and out: fade, fade up, slide, pop, zoom, blur, wipe, word by word or typewriter.
- New title styles: lower third, full-screen slate and chapter card, each with an optional second line.
- Annotations on the screen that follow zooms: spotlight, box with a label, arrow, highlighter and privacy blur.
- Caption styles: karaoke (a box slides behind the word being said), word pop, and bold outlined captions.
- Styled cuts: blur, dip, flash, punch in and whip pan.
- Crossfades: a cut can dissolve between the two clips (a quarter second each side) without changing the video's length.
- B-roll: show a picture or clip over part of the video, inside the screen card or over the whole frame, with the same entrances and exits. The B-roll button copies the file into the project's broll/ folder.

### Security
- Headless Claude edits no longer load your personal Claude Code settings either, so your own allow rules can't let an edit run commands beyond the three `director` checks.
- Claude Code edits can only read the recording's folder, edit plan.json and run the director's describe, still and review. A project folder's own `.claude/` settings and hooks are ignored, and check frames go in the project's `.checks/` folder instead of /tmp.
- YouTube descriptions and recording names from Claude Code run with no tools, from an empty folder.
- What was said and typed in a recording is treated as data, never as instructions. An AI edit that points the recording, camera, music, logos or fonts at a file outside the project is undone, and the reply says so.
- `director still` only writes into the project folder or a temp folder, and won't write through a symlink.
- Shortcut chips only record keys held with ⌘ or ⌃ (⌥ combos type characters, so they stay unlabeled), and nothing is logged while a password field has secure input on.
- Upload links get a random suffix so they can't be guessed, and Settings > Sharing warns when the endpoint isn't HTTPS.
- Releases list the zip's SHA-256 and can be signed with a Developer ID and notarized.

## 0.2.0 (2026-10-12)

The first tagged release. Everything runs on the native Swift engine.

### Recording
- Record the whole screen or one window, with mic and camera. ⌃⌥⌘R starts and stops from any app.
- ⌃⌥⌘M marks a retake: the line you just said is cut and the redo stays. FollowSpot scripts keep only the last take of each line.
- Record without the real cursor and draw a smoothed one from the mouse log.

### Editing
- Claude drafts the edit: talking stays at 1x, typing and waiting speed up, dead air and filler words are cut, and clicks get zooms. Claude checks its own zooms and cuts.
- Ask for edits in plain language with Claude Code (no API key), the Anthropic API, or any OpenAI-compatible endpoint.
- Timeline with clips, audio waveform, words, zooms, layouts and titles; an inspector; Screen Studio keyboard shortcuts; undo and plan history.
- Pause trimming (gentle, normal, tight), with word timings snapped to the measured audio.
- Edit the transcript to cut words.
- Join several recordings into one project.

### Look and sound
- Profiles with your background, fonts, colors, logo and frame, full bleed or padded.
- Intro and outro cards in the profile's look.
- Camera bubble, side by side or full frame, centered on your face, with reframing and color grading.
- Zooms ease in early with a long tail and motion blur.
- Voice normalizing, volume, a limiter, Apple voice isolation, and background music that ducks under speech.

### Export and sharing
- 16:9, 9:16, 1:1 and 4:5 at 720p to 4K, with presets, in a background export queue.
- SRT captions, chapters, an AI-drafted description and smiling-face thumbnails.
- GIF export for docs, and Upload and Copy Link to any S3-compatible bucket.

### Under the hood
- The `sd` CLI always runs the Swift `director`. The Node planner and Remotion renderer are gone.
- CI runs SwiftLint, ShellCheck, the checks and a headless playback test; `macos/smoke-test.sh` drives the app locally.
- [docs/privacy.md](docs/privacy.md) explains what's recorded and what can leave your Mac.

## 0.1.0

The untagged prototype: an ffmpeg recorder, a Node planner and a Remotion renderer.
