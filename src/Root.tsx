import React from "react";
import { Composition, type CalculateMetadataFunction } from "remotion";
import { Screencast } from "./Screencast.tsx";
import { mapSegments, totalFrames } from "./timeline.ts";
import type { RenderProps } from "./types.ts";

// Placeholder used only when the studio opens without --props.
const emptyProps: RenderProps = {
  plan: {
    version: 1,
    source: { video: "screen.mp4", width: 1920, height: 1080, duration: 1 },
    output: { width: 1920, height: 1080, fps: 30 },
    style: { background: ["#1d2b64", "#f8cdda"], padding: 0.06, radius: 14, transition: 0.8 },
    segments: [{ start: 0, end: 1, speed: 1 }],
    zooms: [],
    defaultLayout: "screen",
    layouts: [],
    captions: { enabled: true, maxWords: 7 },
    clickRipples: true,
    shortcutChips: true,
    callouts: [],
  },
  words: [],
  clicks: [],
  shortcuts: [],
};

const calculateMetadata: CalculateMetadataFunction<RenderProps> = ({ props }) => {
  const { output, segments } = props.plan;
  return {
    durationInFrames: totalFrames(mapSegments(segments, output.fps)),
    fps: output.fps,
    width: output.width,
    height: output.height,
  };
};

export const RemotionRoot: React.FC = () => (
  <Composition
    id="Screencast"
    component={Screencast}
    defaultProps={emptyProps}
    calculateMetadata={calculateMetadata}
    durationInFrames={30}
    fps={30}
    width={1920}
    height={1080}
  />
);
