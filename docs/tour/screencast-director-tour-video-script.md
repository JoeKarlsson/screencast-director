# Screencast Director: the tour

**Format:** In-app tour (plays from Getting Started) and the README demo, about 4.5 min
**Words:** about 640 (4.5 min at 140 words a minute)
**Audience:** someone who just opened Screencast Director, or is deciding whether to
**Look:** the Personal Dark profile. No other profiles in the Profile menu while recording (see Before you record).
**Angle:** You talk through your demo once, and the app does the boring part of the edit.

---

## Before you record

- Settings > General: **Profile** set to Personal Dark. Settings > Recording: **Show this app in recordings** on.
- Move any work profiles out of `~/Library/Application Support/Screencast Director/Profiles/` for the take, so the Profile menu only lists Personal and Personal Dark. Put them back after.
- The library should hold only recordings you're happy to show. `publish-demo` (already in Personal Dark) is the sample recording; open it once first so its preview is loaded.
- To get the recording widget into the shot, launch with `open -a "Screencast Director" --args -panelsInScreenshots YES`. Otherwise it stays out of the recording, which is the point of it.
- Start the take from the menu bar or ⌘N. Don't press ⌃⌥⌘R during the take: it stops it.

---

*[Camera: Joe, full frame.]*

I recorded the video you're watching right now in this app. And I didn't edit it. Well, I edited it a little. The app did most of it.

So this is Screencast Director. Not director like Spielberg. Then again, Spielberg yells "cut" a lot, and so does this app. So, kind of like Spielberg.

Because editing a screen recording is the worst part, right? You scrub through every "um," every dead pause, every time you lost your cursor.

*[Screen: the start page. The gallery of recordings, the New Recording button.]*

This is the start page: your recordings, and a big New Recording button. Press it, or Command N, and pick a screen or a single window, your mic, and your camera if you want it. Or from any app, press Control, Option, Command, R, and it just starts.

*[Screen: the recording widget, if it's in the shot. Point at Pause and the clock.]*

While you record, there's a little widget with a clock, Pause, and Stop. It never shows up in the recording. Flub a line? Press Control, Option, Command, M, say it again, and the bad take gets cut for you. It also notes where you click and when you type, but never what you typed.

*[Screen: open publish-demo. Its draft edit is already there.]*

When you stop, it transcribes you right on your Mac and drafts the edit, with one rule. I call it the talking rule. If you're talking, it plays in real time. If you're typing and not talking, it's fast-forward. And if nothing's happening at all, it's gone.

*[Skit: Joe: "Hey, so I spent like eleven seconds looking for my cursor." App voice, flat: "Gone."]*

It also zooms in where you click, and turns what you said into captions.

*[Screen: the timeline. Point at the Clips, Words, Zoom, Layout and Titles tracks.]*

Down here's the timeline. Blue plays in real time, orange is sped up, and the dashed boxes are cuts. Click a cut and hit Restore to put it back, in case it cut your best joke. It won't. Probably.

*[Screen: press Space to play, C to split, Z to add a zoom, then drag the focus box on the preview.]*

If you've used Screen Studio, the keys match. Space plays, J, K and L shuttle, C splits. Z adds a zoom. Drag this box to aim it.

*[Screen: Option Command T opens the transcript. Drag across a sentence, click Cut.]*

You can also edit the words. Open the transcript, select a sentence, and cut it. The video follows.

*[Screen: select a few words, add a lower third. Press A for a box around a button. Then the motion style tiles.]*

From here you can add a title, a lower third with your name, or a box around the button you're talking about. And if there's an API key on screen, blur it. Pick a motion style, like Smooth or Snappy, and every zoom and title moves that way.

*[Screen: the Ask box. Type "cut my retakes and zoom in when I mention the timeline". Let the steps run.]*

Or, and this is the part I actually built it for, you just ask. "Cut my retakes and zoom in when I mention the timeline." You can watch it work: reading the transcript, checking frames, editing the plan. Then it lists what it changed, and the timeline glows where it changed it.

*[Screen: the change list. Undo one change, keep the rest.]*

Don't like one of the changes? Undo just that one. Command Z undoes the whole thing, which makes it the shortcut I use most.

*[Screen: Settings, AI.]*

By default it uses your Claude Code login, so there's no key to paste. Or use an Anthropic key, or any OpenAI-compatible endpoint, even a model on your own machine.

*[Screen: the inspector. Pick Personal Dark in Profile, then set Shape to 9:16.]*

A profile sets your look: the background, fonts, colors, your logo. For a vertical clip, set Shape to 9:16. It crops the screen and follows your clicks, so your code's still readable on a phone. That one's my favorite.

*[Screen: the Export menu, the progress ring, then Publish.]*

Export has presets for YouTube, Shorts, square and LinkedIn. Publish writes your captions, chapters and a description. It even picks thumbnails from frames where you're smiling.

*[Camera: Joe, a big forced grin.]*

So smile at least once. Like this. *[Beat.]* That's a thumbnail now.

*[Screen: Share. Make a GIF, or upload and copy the link.]*

Need it in docs? Make a GIF. Need to send it? Upload it to your own bucket and the link's on your clipboard.

*[Camera: Joe, full frame, then the editor behind him.]*

And it all stays on your Mac: the recording, the transcript, the clicks. Nothing leaves unless you ask the AI or share it.

Remember the talking rule? You talk, and the app handles the boring part of the edit. I made this video the same way.

---

*Read-aloud flags: The Spielberg bit and the cursor skit depend on timing, so ad-lib them if the read feels stiff. Say the shortcuts naturally ("Control, Option, Command, R"), not letter by letter. The forced grin needs a real beat before "That's a thumbnail now." If a section drags, Ask Claude to cut it after; that's the demo.*

*Lines I left for you (your jokes, which a strict scanner flags): "Not director like Spielberg." / "So, kind of like Spielberg." / the "Gone." skit / "It won't. Probably." / "That's a thumbnail now." / "the talking rule" (a named rule with a callback, as in your platinum rule).*
