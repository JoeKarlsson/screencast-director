# Targets by length

What hit videos of each length do, measured on 31 of them (six or seven per bucket, dev tools, homelab, data and AI) and checked against platform docs and studies. Sources and method are in [sources.md](sources.md).

Buckets go by **output** length, the way `planSeconds` measures it. Vertical video goes by the 60 s column at any length. Each social clip counts at its own length and format.

| | 60 s (up to 90 s) | 3 min (90 s to 4 min) | 5 min (4 to 8 min) | 20 min (8 to 35 min) | 60 min (over 35 min) |
|---|---|---|---|---|---|
| Before the first word | nothing (0 s in 6 of 6 hits) | 0 s median; a logo card up to 8 s was seen | a greeting of 3 s or less | 0 s (1 of 6 greets, under 1 s) | cut host intros and housekeeping; first point by a median of 41 s |
| Title proved | first frame, claim by 3 s | by about 8 s | named by about 16 s, result shown first | named at 0 s, payoff before 2 min | strongest line first is the advice; 1 of 7 hits did it |
| First new hook | by about 11 s | about 15 to 20 s | about 40 s | at each chapter change | at each chapter change |
| Re-hook spacing (median) | 11 s | 21 s | 39 s | 58 s | every chapter, 2 to 6 min |
| Longest with nothing new, screen-led (median / ceiling) | 4 / 6 s | 6 / 20 s | 15 / 36 s | 24 / 45 s | 26 / 60 s (a slide being read can go longer) |
| Chapters | none | none needed (hits list 5 to 8 in the description) | 5 to 10, about one a minute | about 10, about one every 2 min | 10 to 28, every 2 to 6 min |
| Asks | none, or one spoken line over the payoff | at the end (last quarter) | at the end, plus tool links where they're used | an early ask after the first payoff is fine; a sponsor at 20 to 57%, on a chapter change, with the screen moving | at most 2 breaks; links in the description |
| After the last payoff | 3 s or less (median 3) | about 15 s plus end screen | about 20 s plus end screen | about 20 s of content, then 5 to 20 s of end screen | about 30 s (median 29) |

## What `director review` checks

Its `RETENTION` lines check the parts of this table the plan can measure. Each limit sits at or just past the worst seen in a hit, so a good edit stays quiet. A line is a judgment call, not a build failure: fix it, or say why it stays.

| Line | Fires when | 60 s | 3 min | 5 min | 20 min | 60 min |
|---|---|---|---|---|---|---|
| `intro` | the first spoken word (intro card included) comes later than | 0.5 s | 1 s | 3 s | 3 s | 30 s |
| `hook` | a vertical edit or clip has no title, overlay or caption on screen at 0:00 | yes | | | | |
| `still` | the screen is what you watch and nothing new happens on it for longer than | 6 s | 20 s | 36 s | 45 s | 60 s |
| `hold` | the screen cuts away (to the face, B-roll or a full-frame animation) within 0.5 s of a click or the end of typing | all | all | all | all | all |
| `tail` | the video runs on after the last spoken word, not counting the outro card, by more than | 3 s | 15 s | 20 s | 25 s | 30 s |
| `chapters` | the chapter titles make fewer than 3 YouTube chapters, or a chapter runs longer than | | | 2 min | 5 min | 10 min |

"Something new" for `still` is a cut, zoom, layout change, title, annotation, B-roll, sticker, punch-in, click, keystroke, screen motion, an animation playing or a sped-up stretch. A face filling the frame (camera or side layout, or the split in vertical) counts as something happening, because a talking face is change. The limits live in `EngagementTargets` (`macos/Sources/DirectorCore/Retention.swift`).

## YouTube's rules

- Chapters need at least 3, the first at 0:00, each at least 10 s. `publish` writes them from the plan's chapter titles (or its plain titles when it has none; never lower thirds or slates).
- End screens use the last 5 to 20 s, on a video of at least 25 s.
- The Intro moment in YouTube's analytics is the share still watching at 30 s.
- Shorts and Reels run up to 3 min. A square or vertical upload of 3 min or less becomes a Short.
- A Short over 1 min with any Content ID claim is blocked, so check the music on a long Short.
- Shorts views count every play and replay, but engaged views (which pay) don't count loops.

## By content type

**Screen demos and tutorials.** Open on the finished result for 3 to 5 s, then the problem (O3). Play waits, installs and boilerplate typing fast, and the command or click that matters at 1x (V5). Hold each result about a second before cutting away (V4). The two product demos measured proved their title late (65 to 69 s), which is the norm the advice is trying to fix, not a target.

**Talking-head explainers.** Hits ranged from 0 to 25 cuts a minute; cut rate doesn't predict anything. Use the face for the hook, the transitions and the opinions, and go screen-only or small picture-in-picture during dense steps (V3).

**Vertical Shorts.** The first frame carries the hook and makes sense muted: a hook title or a caption from the first word (O2). End on the payoff (E1), and if the last line leads back into the first, let it loop (E3). A clip cut from a longer video must stand alone (E4, `video-clips`).

**Talks and streams.** Cut host intros, mic checks and room or date housekeeping (T1). Show slides full frame when they're dense or being pointed at, picture-in-picture only over empty slide space, and avoid a 50/50 split at 1080p (T2; low confidence, so offer it rather than impose it). In live coding keep the errors that teach and cut typos and dead ends; silence over 30 s loses viewers (T4). TV is the most-used screen for YouTube in the US, and long videos are where it shows, so chapter titles and on-screen type must read from the couch (T5). Ask Joe what to do with Q&A each time.

## Confidence

- **High:** a platform rule or a controlled study, and the teardown agrees: the opening limits, chapters' rules, ending on the payoff, captions on vertical, signals on their word.
- **Medium:** consistent practitioner advice plus the teardown: re-hook spacing, the `still` ceilings, `hold`, the tail limits beyond Shorts, sponsor placement.
- **Low:** sources conflict: slide layouts in talks.

Six or seven hit videos per bucket show what works but not what fails, so treat the medians as targets and the ceilings as limits, not as laws.
