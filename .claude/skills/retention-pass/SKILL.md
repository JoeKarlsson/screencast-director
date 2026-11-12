---
name: retention-pass
description: Check a Screencast Director edit's structure against what hit videos of the same length do (opening, re-hooks, stretches with nothing new, ending, chapters, asks), write the findings to .checks/retention.md with output timestamps and the plan edit for each, then make the edits the user approves. Uses `director review`'s RETENTION lines, the transcript and a read-only second opinion. Use when the user says /retention-pass, "retention pass", "will people watch this", "tighten the hook", "fix the opening/ending", or from edit-screencast's quality pass on an edit that will be published.
---

# Retention pass

Arguments: a project (a folder under `projects/`, or a recording under `~/Movies/Screencast Director/`). Call it `<p>` below. Use `bin/director` and `bin/sd` from the repo, never a `.build` path.

The rules and numbers live in `../edit-screencast/references/engagement/`:

- [by-length.md](../edit-screencast/references/engagement/by-length.md): the targets for each length bucket, and what the engine checks
- [openings.md](../edit-screencast/references/engagement/openings.md): the hook, and how to build a cold open with `move` and `repeat`
- [retention-beats.md](../edit-screencast/references/engagement/retention-beats.md): shoulder taps, re-hooks, keeping the screen alive, chapters, talks
- [endings-and-ctas.md](../edit-screencast/references/engagement/endings-and-ctas.md): ending on the payoff, asks

Read by-length.md every time, and the others for the findings you write up.

## 1. Measure

1. `bin/director describe <p>`: output length, the timeline with what's said in each kept range and its output time, and the titles.
2. `bin/director review <p> --retention`: the `RETENTION` lines. The header names the length bucket (vertical goes by the 60 s rules at any length; each social clip is checked at its own length).
3. Read `script.md` if there is one, and the title if the user gave one (or `publish/`). The title is the promise the opening has to keep.
4. Save a "before" contact sheet for the second opinion: `bin/director contact-sheet <p> <p>/.checks/before.png`.

## 2. Judge

Go through these in order. Each finding gets an output timestamp, the rule ID from the references, what's wrong in one line, and the fix as a plan edit or a `director` command.

1. **Opening** (O1 to O4, V3, T1). What's the title's promise, and at what output second does the footage first prove it? Is it inside the bucket's window? List greetings, "in this video" lines and intro cards before it. If the proof comes late, propose the cold open: the source range and the exact `director repeat` or `move` command (openings.md, "Building the opening").
2. **Re-hooks** (R1, R2). Mark each section change (titles, topic changes in the transcript). Does each one close a question and open the next, or close on a flat recap? Report the longest stretch with no pull-forward line against the bucket's median spacing.
3. **Screen** (R4, V2, V4, V5). Each `still` and `hold` line, with the tool from retention-beats.md that fits what's being said there. Waits played at 1x, and decisive moments sped up.
4. **Middle** (M1, M3). `chapters` lines, chapter titles that give away a reveal, and an ask or sponsor in the wrong place.
5. **Ending** (E1 to E4). Find the payoff. Everything after it is tail: list recap and wrap-up lines with their times. On vertical, look for a loop seam.
6. **Talks and streams** (T1, T2, T4, T5), when it is one. Ask the user what to do with Q&A; don't decide it.

Then ask the `cut-retention-reviewer` agent for a read that isn't anchored on yours. Give it the project path, the bucket and the title, not your findings. Merge what it finds that you missed; where you disagree, keep both and say so.

## 3. Write it up

Write `<p>/.checks/retention.md`:

```markdown
# Retention pass: <project> (<bucket>, <output length>)

Promise: <one line>. Proved at <out time> (target: <bucket window>).

| # | Out | Rule | Finding | Fix |
|---|---|---|---|---|
| 1 | 0:00 | O1 | 4 s greeting before the point | `bin/director cut <p> 1.5 5.6` |

## Lines the user could record
- <only when the footage has no line to fix a finding; quote the gap, suggest one sentence>

## Left alone
- <findings you'd not act on, and why>
```

Most important first: opening, then ending, then the rest. Keep it to what changes retention; polish belongs to `review`'s POLISH lines.

## 4. Edit

Show the user the table and ask which to make, unless they already said "go ahead" or "fix them". Then make those edits with the `director` commands and plan edits named, and run the edit skill's checks on what changed: `validate`, `describe` to see that every cut lands between sentences, `review --retention` to see that the lines it fired on are gone, and stills at the moments you changed. Never invent a spoken line, and never cut the payoff to meet a length.

Report the edits made with output timestamps, the RETENTION lines still standing and why, and the lines the user could record.
