import React, { useMemo } from "react";
import { AbsoluteFill, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from "remotion";
import {
  cameraAt,
  layoutAt,
  layoutsToOut,
  mapSegments,
  srcToOut,
  zoomsToOut,
  type MappedSegment,
  type Rect,
} from "./timeline.ts";
import type { RenderProps, Word } from "./types.ts";

const FADE_FRAMES = 3;

/** One OffthreadVideo per kept segment, so cuts and speed changes are exact. */
const SegmentedVideo: React.FC<{
  src: string;
  mapped: MappedSegment[];
  fps: number;
  offset?: number;
  muted?: boolean;
  style: React.CSSProperties;
}> = ({ src, mapped, fps, offset = 0, muted, style }) => (
  <>
    {mapped.map((s) => {
      // A file that started later than the screen (offset < 0) has nothing to show at first.
      const lead = Math.max(0, Math.round((-(s.start + offset) * fps) / s.speed));
      if (lead >= s.frames) return null;
      return (
        <Sequence key={s.outStart} from={s.outStart + lead} durationInFrames={s.frames - lead} premountFor={fps}>
          <OffthreadVideo
            src={src}
            trimBefore={Math.max(0, Math.round((s.start + offset) * fps))}
            playbackRate={s.speed}
            muted={muted || s.speed > 1.01}
            // Short fades at each cut hide clicks in the audio.
            volume={(f) => Math.min(1, (f + 1) / FADE_FRAMES, (s.frames - lead - f) / FADE_FRAMES)}
            style={style}
          />
        </Sequence>
      );
    })}
  </>
);

function rectStyle(r: Rect): React.CSSProperties {
  return {
    position: "absolute",
    left: r.x,
    top: r.y,
    width: r.w,
    height: r.h,
    borderRadius: r.r,
    opacity: r.opacity,
    overflow: "hidden",
  };
}

type Page = { words: { text: string; startF: number; endF: number }[]; startF: number; endF: number };

/** Groups kept words into short caption pages, breaking on pauses and length. */
function captionPages(words: Word[], mapped: MappedSegment[], fps: number, maxWords: number): Page[] {
  const pages: Page[] = [];
  let cur: Page | null = null;
  let lastEnd = -Infinity;
  for (const w of words) {
    const startF = srcToOut(mapped, w.start, fps);
    if (startF === null) continue;
    const endF = srcToOut(mapped, Math.max(w.start, w.end - 0.001), fps) ?? startF + 3;
    const pause = w.start - lastEnd > 0.8;
    if (!cur || pause || cur.words.length >= maxWords) {
      cur = { words: [], startF, endF };
      pages.push(cur);
    }
    cur.words.push({ text: w.text.trim(), startF, endF });
    cur.endF = endF;
    lastEnd = w.end;
  }
  return pages;
}

export const Screencast: React.FC<RenderProps> = ({ plan, words, clicks, shortcuts }) => {
  const frame = useCurrentFrame();
  const fps = plan.output.fps;
  const mapped = useMemo(() => mapSegments(plan.segments, fps), [plan.segments, fps]);
  const zooms = useMemo(() => zoomsToOut(plan.zooms, mapped, fps), [plan.zooms, mapped, fps]);
  const layouts = useMemo(() => layoutsToOut(plan, mapped), [plan, mapped]);
  const pages = useMemo(
    () => (plan.captions.enabled ? captionPages(words, mapped, fps, plan.captions.maxWords) : []),
    [words, mapped, fps, plan.captions],
  );
  const outClicks = useMemo(
    () =>
      plan.clickRipples
        ? clicks.flatMap((c) => {
            const f = srcToOut(mapped, c.t, fps);
            return f === null ? [] : [{ ...c, f }];
          })
        : [],
    [clicks, mapped, fps, plan.clickRipples],
  );
  const outShortcuts = useMemo(
    () =>
      plan.shortcutChips
        ? shortcuts.flatMap((k) => {
            const f = srcToOut(mapped, k.t, fps);
            return f === null ? [] : [{ ...k, f }];
          })
        : [],
    [shortcuts, mapped, fps, plan.shortcutChips],
  );

  const half = Math.max(1, Math.round((plan.style.transition * fps) / 2));
  const cam = cameraAt(frame, zooms, half);
  const boxes = layoutAt(frame, plan, layouts, half);
  const screen = boxes.screen;

  const videoStyle: React.CSSProperties = { width: "100%", height: "100%", objectFit: "cover" };

  const page = pages.find((p) => frame >= p.startF && frame < p.endF + fps * 0.4);
  const chip = [...outShortcuts].reverse().find((k) => frame >= k.f && frame < k.f + fps * 1.2);
  const callout = plan.callouts.find((c) => {
    const s = srcToOut(mapped, c.start, fps);
    const e = srcToOut(mapped, c.end, fps);
    return s !== null && frame >= s && frame < (e ?? s + fps * 3);
  });

  const [bg1, bg2] = plan.style.background;

  return (
    <AbsoluteFill style={{ background: `linear-gradient(135deg, ${bg1}, ${bg2})`, fontFamily: "Inter, -apple-system, Helvetica, sans-serif" }}>
      {/* Screen card */}
      <div style={{ ...rectStyle(screen), boxShadow: "0 30px 80px rgba(0,0,0,0.45)" }}>
        <div
          style={{
            position: "absolute",
            width: screen.w,
            height: screen.h,
            transformOrigin: "0 0",
            transform: `translate(${-(cam.x * cam.scale - 0.5) * screen.w}px, ${-(cam.y * cam.scale - 0.5) * screen.h}px) scale(${cam.scale})`,
          }}
        >
          <SegmentedVideo src={staticFile(plan.source.video)} mapped={mapped} fps={fps} style={videoStyle} />
          {outClicks.map((c) => {
            const age = (frame - c.f) / (fps * 0.5);
            if (age < 0 || age > 1) return null;
            const size = 18 + age * 50;
            return (
              <div
                key={c.f}
                style={{
                  position: "absolute",
                  left: c.x * screen.w - size / 2,
                  top: c.y * screen.h - size / 2,
                  width: size,
                  height: size,
                  borderRadius: "50%",
                  border: `${3 / cam.scale}px solid rgba(255,255,255,${0.9 * (1 - age)})`,
                  background: `rgba(120,160,255,${0.25 * (1 - age)})`,
                }}
              />
            );
          })}
        </div>
      </div>

      {/* Camera */}
      {plan.camera && boxes.cam.opacity > 0.01 ? (
        <div style={{ ...rectStyle(boxes.cam), boxShadow: "0 20px 60px rgba(0,0,0,0.5)", border: "3px solid rgba(255,255,255,0.85)" }}>
          <SegmentedVideo
            src={staticFile(plan.camera.video)}
            mapped={mapped}
            fps={fps}
            offset={plan.camera.offset}
            muted
            style={videoStyle}
          />
        </div>
      ) : null}

      {/* Callout */}
      {callout ? (
        <div style={{ position: "absolute", top: plan.output.height * 0.06, width: "100%", textAlign: "center" }}>
          <span style={{ background: "rgba(15,15,20,0.85)", color: "white", padding: "14px 28px", borderRadius: 14, fontSize: 40, fontWeight: 700 }}>
            {callout.text}
          </span>
        </div>
      ) : null}

      {/* Shortcut chip */}
      {chip ? (
        <div style={{ position: "absolute", bottom: plan.output.height * 0.2, width: "100%", textAlign: "center" }}>
          <span style={{ background: "rgba(15,15,20,0.85)", color: "white", padding: "10px 22px", borderRadius: 12, fontSize: 44, fontWeight: 600, letterSpacing: 4 }}>
            {chip.label}
          </span>
        </div>
      ) : null}

      {/* Captions */}
      {page ? (
        <div style={{ position: "absolute", bottom: plan.output.height * 0.07, width: "100%", display: "flex", justifyContent: "center" }}>
          <div style={{ background: "rgba(10,10,14,0.78)", padding: "12px 26px", borderRadius: 14, fontSize: 42, fontWeight: 600, maxWidth: "80%", textAlign: "center", lineHeight: 1.3 }}>
            {page.words.map((w, i) => (
              <span key={i} style={{ color: frame >= w.startF ? "#ffffff" : "rgba(255,255,255,0.5)" }}>
                {w.text}{" "}
              </span>
            ))}
          </div>
        </div>
      ) : null}
    </AbsoluteFill>
  );
};
