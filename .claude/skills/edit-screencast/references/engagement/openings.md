# Openings

The first seconds decide most of a video's audience. YouTube's own analytics call the share still watching at 30 s the "Intro" moment, and its advice for a weak one is to bring compelling content earlier. This file is how to build that opening in the edit, out of footage that already exists. Limits by length are in [by-length.md](by-length.md).

## The rules

**O1. Nothing before the first spoken content** (high, engine: `RETENTION intro`). No greeting, channel intro, logo sting or intro card first. Shorts and 3 min videos start talking at once; a 5 min video can get away with a greeting of about 3 s. Branding, if any, goes after the hook. A logo opener cost 14% in TikTok and VidMob's ad data, and vidIQ measured 4 to 5% of viewers gone in the first 2 to 4 s of a slow start.

Cut these when they come before the point:

- "Hey everyone", "Hi, I'm Joe", "Welcome back to the channel"
- "In this video I'm going to show you", "Today we're going to", "So, um"
- "Before we start, make sure to subscribe"
- an `intro` card (set `intro.enabled` false) or a title card that only names the video

**O2. Vertical: the first frame carries the hook** (high, engine: `RETENTION hook`). Something on screen at 0:00 says what this is, muted: a hook title on the first words, or captions starting with the first word. The claim lands by 3 s (Hoyos says 1 s; Instagram's head says 3). For a social clip, the clip's `title` is its hook title.

**O3. Tutorials and demos open on the result** (medium, skill). A 3 to 5 s "sneak peek" of the finished thing, then the problem. YouTube's playbook advises it and van der Meij's 2014 study backs it for tutorials, but the measured product demos didn't do it, so offer it rather than impose it.

**O4. Prove the title inside the bucket's window** (high, skill). If the strongest moment comes late, play it first. When a video's main point landed at 15 s instead of 1:43, average view percentage rose from 34% to 41% (AIR Media-Tech).

**V3. The face carries the hook** (high, skill). Open on the camera (or the split in vertical) for the claim, then go to the screen for the steps.

**T1. Talks start with the talk** (high, skill). Cut the host's introduction, salutations, mic checks and anything about this room or this date. Guo's edX study found chopped lectures broke on remarks like "room 36-144".

## Building the opening

1. **Find the title's promise.** Read the title (`publish/` or the script) and say in one line what the viewer clicked for.
2. **Find where the footage proves it.** In `bin/sd describe <name>` and the transcript, look for the line or moment that delivers it: the result working, the number, the before and after, the strongest opinion. Note its source range, from the start of its sentence to the end of the payoff.
3. **Check how late it plays.** If it lands after the bucket's "title proved" time, it needs to move.
4. **Bring it forward:**
   - `bin/director repeat projects/<name> <start> <end>` plays the range first and keeps it in its place too. Use it for a result-first tease that the video will reach again.
   - `bin/director move projects/<name> <start> <end>` plays it first and removes it from where it was. Use it for a line that works better as the opening than where it was said.
   - `--before <t>` puts it before source time `t` instead of at the very start.
   - Keep the moved piece 3 to 8 s for Shorts and up to about 15 s for long videos, and cut it on sentence boundaries.
5. **Cut the warm-up** between the old start and the first useful line with `director cut`.
6. **Label it** if it needs one: a `title` callout on the first words that names what the viewer gets, not the sentence being said (V2). On vertical this is also O2's hook title.
7. **Check the seam.** Play the cold open into the real start in `describe`: the jump back should be obvious (a cut back to the start reads as "here's how we got there"). The renderer marks it as a jump back, so effects that react to cuts treat it as one.

If no moment in the footage proves the title, don't invent one. Say so, and suggest a line Joe could record (a one-sentence claim of the result) or a title change.
