# Retention beats

What keeps a viewer between the opening and the ending: spoken re-hooks at each section change, and something new on screen in between. Limits by length are in [by-length.md](by-length.md).

## Shoulder taps

"Shoulder tap" is Joe's word; no source defines it. It covers the devices that sources do define:

- **Pull forward at a section's end** (Adam Ivy's "nudge"): close the question this section asked and open the next one. "That's the connection working. But it can only see one app, so..."
- **A new hook early** (DiGiovanni's "new hook", about 15 s in): once the opening's promise is made, a second reason to stay.
- **A visual tap:** something new on screen between the spoken ones (R4 below).

The common advice to re-hook at the 30% and 50% marks has no source behind it beyond vendor blogs. Hits re-hook at every section change instead.

## The rules

**R1. End each section on a pull forward, not a flat recap** (medium, skill). Find the section ends in the transcript (each chapter title, or each topic change). If a section closes on a summary ("so that's how X works") and the next opens cold, flag it. In the edit you can:

- cut the recap line, so the section ends on its payoff
- move the next section's question up to the cut ("but here's the catch")
- put a title or sticker on the line that opens the next question

If no line pulls forward, suggest one Joe could record. The wording is a script job.

**R2. Re-hook spacing grows with length** (medium, skill). Median gaps between spoken re-hooks in hits: 11 s at 60 s, 21 s at 3 min, 39 s at 5 min, 58 s at 20 min, and every chapter change (2 to 6 min) in hour-long videos. Report the longest stretch with no pull-forward line; there's no fixed percentage to hit.

**R4. No screen-led stretch past the ceiling with nothing new** (medium, engine: `RETENTION still`). The cut rate in hits runs from 0 to 25 a minute (Theo, ThePrimeagen and IBM's RAG lightboard have no cuts at all), so cut rate isn't the measure. What holds steady is new information on screen: each hit changed visibly every 2 to 4 s, and 61% of interaction peaks in Kim's edX study fell on visual transitions. "A pattern interrupt every 60 to 90 s" has no data behind it either.

When `still` fires, pick the change that carries meaning for that moment:

| What's being said | Tool |
|---|---|
| a specific control, line or number | zoom (`zooms`) or annotation (box, highlight, arrow) |
| an opinion or a joke | layout to `camera`, or a camera punch-in |
| a new idea or term | title callout naming it, or an animation (`/animate`) |
| something that exists outside the screen | B-roll (`inserts`) |
| a reaction | sticker (`sticker` insert) |
| nothing: a wait, an install, boilerplate typing | speed the segment up |

**V1. Signals land on their word** (high, existing). A title or box appears on the word it names, one at a time. Timing visuals to the word was the largest effect in Mayer's meta-analyses (d=1.31); signaling helps (d=0.70) when used sparingly.

**V2. On-screen text is keywords, not the sentence** (high, skill). Commands, names and numbers. Text that duplicates the narration had no benefit (d=0.10). Labels sit beside the thing they name (d=0.82).

**V4. Hold the result** (medium, engine: `RETENTION hold`). Don't cut away from finished code or a result before it can be read: about a second or more. In Kim's study, 23% of interaction peaks were viewers going back to code that had left the screen.

**V5. Speed the waits, not the moment** (medium, skill). Waits, installs and boilerplate typing play fast (2x costs almost nothing; typing can go to 12x). The decisive command or click plays at 1x, since the tallest peaks come right before a command runs.

**V6. Trim pauses, keep the beats** (high, existing: `director pauses normal`). Keep a beat after each on-screen result and after a punchline. Don't over-cut a talk.

## The middle

**M1. Chapters for 5 min and up** (high for the rules, medium for the spacing; engine: `RETENTION chapters`). At least 3, from 0:00, each at least 10 s; about one a minute at 5 min, one every 2 min at 20 min, every 2 to 6 min at 60 min. They come from the plan's titles (`publish` writes them). In a narrative essay, don't name the reveal in its chapter title. Keep chapters in the description by default; on-screen chapter cards aren't needed.

**M3. A sponsor or mid-video ask** (medium, skill). After the first payoff, on a chapter change, at 20 to 57% of the way through in hits (never in the first 3 min, per Galloway), with the screen still moving during it.

## Talks and streams

**T2. Slides** (low, skill; offer, don't enforce). Full frame when a slide is dense or being pointed at; picture-in-picture only over empty slide space; avoid a 50/50 split at 1080p. Sources conflict and every hit talk kept one fixed layout.

**T4. Live coding** (medium, skill). Keep errors that teach something; cut typos and dead ends; speed typing and waits. Silence over 30 s loses viewers.

**T5. TV legibility** (medium, skill). Long videos get watched on TVs, so chapter titles and on-screen type must be readable from across a room.
