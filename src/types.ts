// The edit plan: a small JSON file that describes the whole edit.
// `sd plan` generates it; Claude (or you) edits it; `sd render` renders it.
// All times are in SOURCE seconds (positions in the raw screen recording).

export type Segment = {
  start: number;
  end: number;
  /** 1 = real time. Segments faster than 1 are rendered muted. */
  speed: number;
  note?: string;
};

export type Zoom = {
  start: number;
  end: number;
  /** Focus point, 0..1 across the recorded screen. */
  x: number;
  y: number;
  /** 1 = no zoom, 2 = twice as close. */
  scale: number;
  note?: string;
};

export type LayoutMode = "screen" | "pip" | "side" | "camera";

export type LayoutRange = {
  start: number;
  end: number;
  mode: LayoutMode;
  note?: string;
};

export type Callout = {
  start: number;
  end: number;
  text: string;
};

export type Plan = {
  version: 1;
  source: {
    video: string;
    width: number;
    height: number;
    duration: number;
  };
  camera?: {
    video: string;
    /** Seconds to add to a screen time to get the same moment in the camera file. */
    offset: number;
  };
  output: { width: number; height: number; fps: number };
  style: {
    /** Two colors for the background gradient. */
    background: [string, string];
    /** Space around the screen, as a fraction of output height. */
    padding: number;
    radius: number;
    /** Seconds a zoom or layout change takes to ease in or out. */
    transition: number;
  };
  /** Kept ranges, ascending and non-overlapping. Anything not listed is cut. */
  segments: Segment[];
  zooms: Zoom[];
  defaultLayout: LayoutMode;
  layouts: LayoutRange[];
  captions: { enabled: boolean; maxWords: number };
  clickRipples: boolean;
  /** Show chips for keyboard shortcuts (⌘K and friends). */
  shortcutChips: boolean;
  callouts: Callout[];
};

export type Word = { text: string; start: number; end: number };
export type Click = { t: number; x: number; y: number };
export type Shortcut = { t: number; label: string };

/** Everything the renderer needs. Built from plan.json + analysis files by `sd render`. */
export type RenderProps = {
  plan: Plan;
  words: Word[];
  clicks: Click[];
  shortcuts: Shortcut[];
};
