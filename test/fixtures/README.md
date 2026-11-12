# Test fixtures

## talking-head.mp4

40 seconds of NASA astronaut Don Pettit talking to camera on the International Space Station, used by
`macos/media-test.sh` for the face steps (thumbnail faces, face centering, the person cutout and lip sync).

- Source: "NASA Astronaut Don Pettit Talks with KOIN-TV, Portland, Oregon - April 16, 2025 (iss072m261061434)",
  NASA Johnson Space Center
- URL: https://commons.wikimedia.org/wiki/File:NASA_Astronaut_Don_Pettit_Talks_with_KOIN-TV,_Portland,_Oregon_-_April_16,_2025_(iss072m261061434).webm
- License: public domain (a work of NASA, a US federal agency; marked "Public domain" on Wikimedia Commons)
- Trim: 0:45-1:25 of the original, cropped to the 960x540 region at (480, 120) to frame the face,
  scaled to 640x360 at 30 fps, H.264 CRF 30, mono AAC 48 kbps:

      ffmpeg -ss 45 -t 40 -i original.webm -vf 'crop=960:540:480:120,scale=640:360,fps=30' \
        -c:v libx264 -preset slow -crf 30 -pix_fmt yuv420p -c:a aac -ac 1 -b:a 48k -movflags +faststart talking-head.mp4

## whisper-cli.json

Real whisper-cli output (`-ml 1 -sow -oj`, the flags `Analyzer.transcribe` uses, model ggml-base.en) for
`say "Record the screen, then edit the video by changing a plan."` after 1.5 s of silence. Two hand edits:
the model path is cut to its file name, and a `[BLANK_AUDIO]` item is added at the end so the conversion's
skip rule is checked. `macos/media-test.sh` checks the conversion to transcript.json; no model runs in tests.

## themes/probe

A minimal animation theme for `macos/animate-test.sh`: its CSS paints the stage black, its stroke hook thickens the lines, and its marks replace the oval, so the test can see each piece of a pack theme apply.
