// animate-test.sh's probe theme: its hooks leave marks the test can see.
"use strict";
THEMES.probe = {
  setup({ stage }) { stage.dataset.probe = "set up"; },
  stroke: (p, width) => width * 3,
  curve: (a, b, t, seed) => squiggle(a, b, t, seed),
};
