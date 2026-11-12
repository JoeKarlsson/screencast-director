# Third-party notices

Screencast Director is MIT licensed (see [LICENSE](LICENSE)). It ships with, or builds against, the work of others listed here.

## Code

| Project | Used for | License | Copyright | Full text |
|---|---|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Speech to text, on your Mac. `macos/build-whisper.sh` builds `whisper-cli` from that repo to bundle it; without it the app uses Homebrew's. | MIT | The ggml authors | [LICENSE](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE) |
| [lottie-web](https://github.com/airbnb/lottie-web) 5.12.2 | Playing Lottie animations (`lottie_svg.min.js`, the SVG-only build) | MIT | 2015 Bodymovin | [lottie-LICENSE.md](macos/Resources/animations/vendor/lottie-LICENSE.md) |
| [HyperFrames](https://github.com/heygen-com/hyperframes) | The `chart` template's staging and timing are adapted from HyperFrames catalog entries. No HyperFrames code, fonts or assets are included. | Apache-2.0 | HeyGen | [hyperframes-NOTICE.md](macos/Resources/animations/vendor/hyperframes-NOTICE.md) |

## Music

Every built-in track is from [FreePD](https://freepd.com), released under CC0 1.0 (public domain). Composers: Rafael Krux, Kevin MacLeod and Bryan Teoh. The track list with sources is in [macos/Resources/music/CREDITS.md](macos/Resources/music/CREDITS.md).

## Sound effects

Every built-in sound is from [Freesound](https://freesound.org) under CC0 1.0 (public domain). The authors and source links for each sound are in [macos/Resources/sounds/CREDITS.md](macos/Resources/sounds/CREDITS.md).

## Test footage

`test/fixtures/talking-head.mp4` is a trimmed clip of NASA astronaut Don Pettit talking to KOIN-TV from the International Space Station (NASA Johnson Space Center, April 16, 2025). It's a work of NASA and in the public domain. Source and trim details are in [test/fixtures/README.md](test/fixtures/README.md).

## Trademarks

The brand logos in `macos/Resources/animations/logos/` (Asana, Google Ads, HubSpot, Jira, OpenAI and ChatGPT, QuickBooks, Salesforce, Shopify, Slack, Snowflake, Stripe, Xero and Zendesk) are trademarks of their owners. They're included only so explainer animations can show the products a video talks about. Their use doesn't imply any endorsement of, or affiliation with, Screencast Director.
