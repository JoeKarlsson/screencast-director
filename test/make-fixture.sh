#!/usr/bin/env bash
# Builds a synthetic project (projects/<name>) for end-to-end testing without a real recording.
#   0-4s   speech                       -> keep 1x
#   4-7s   silence, frozen screen       -> cut
#   7-10s  typing events, no speech     -> 3x + zoom
#   10-14s speech (+ click, ⌘K)         -> keep 1x
#   14-17s silence, moving box          -> 4x
#   17-20s speech                       -> keep 1x
# A green bar across the top grows 96 px per source second (ticks every second),
# so renders can be checked frame by frame.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
name=${1:-fixture}
dir="$ROOT/projects/$name"
rm -rf "$dir"; mkdir -p "$dir/.tmp"

say -o "$dir/.tmp/a.aiff" "Welcome. Today I will show you how this works."
say -o "$dir/.tmp/b.aiff" "Now I click the search box and press command K to open the palette."
say -o "$dir/.tmp/c.aiff" "And that is the whole demo. Thanks for watching."

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x202833:s=1920x1080:r=30:d=20" \
  -f lavfi -i "color=c=0x6ee7b7:s=1920x40:r=30:d=20" \
  -f lavfi -i "color=c=0xe2a04a:s=300x200:r=30:d=20" \
  -i "$dir/.tmp/a.aiff" -i "$dir/.tmp/b.aiff" -i "$dir/.tmp/c.aiff" \
  -filter_complex "\
[0:v][1:v]overlay=x='t*96-w':y=0,drawbox=x=1200:y=250:w=500:h=120:color=white@0.9:t=fill,\
drawbox=x=250:y=780:w=300:h=100:color=0x4a90e2:t=fill[base];\
[base][2:v]overlay=x='if(between(t,14,17),200+(t-14)*400,if(gt(t,17),1400,200))':y=450,\
\
drawbox=x=96:y=0:w=3:h=60:color=white:t=fill,drawbox=x=192:y=0:w=3:h=60:color=white:t=fill,drawbox=x=288:y=0:w=3:h=60:color=white:t=fill,drawbox=x=384:y=0:w=3:h=60:color=white:t=fill,drawbox=x=480:y=0:w=3:h=60:color=white:t=fill,drawbox=x=576:y=0:w=3:h=60:color=white:t=fill,drawbox=x=672:y=0:w=3:h=60:color=white:t=fill,drawbox=x=768:y=0:w=3:h=60:color=white:t=fill,drawbox=x=864:y=0:w=3:h=60:color=white:t=fill,drawbox=x=960:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1056:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1152:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1248:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1344:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1440:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1536:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1632:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1728:y=0:w=3:h=60:color=white:t=fill,drawbox=x=1824:y=0:w=3:h=60:color=white:t=fill[v];\
[3:a]adelay=300|300[a];[4:a]adelay=10200|10200[b];[5:a]adelay=17200|17200[c];\
[a][b][c]amix=inputs=3:normalize=0,apad,atrim=0:20[aout]" \
  -map "[v]" -map "[aout]" -c:v libx264 -pix_fmt yuv420p -c:a aac -t 20 "$dir/screen.mp4"

cat > "$dir/source.json" <<JSON
{ "video": "screen.mp4", "width": 1920, "height": 1080, "duration": 20, "captureStart": 1000 }
JSON

{
  echo '{"type":"meta","clock":"uptime_raw","t":1000}'
  echo '{"type":"click","t":1007.0,"x":0.75,"y":0.29}'
  for i in $(seq 0 17); do printf '{"type":"key","t":%s,"x":0.75,"y":0.29}\n' "$(echo "1007.2 + $i * 0.15" | bc)"; done
  echo '{"type":"click","t":1011.2,"x":0.21,"y":0.77}'
  echo '{"type":"key","t":1012.3,"x":0.21,"y":0.77,"label":"⌘K"}'
} > "$dir/events.jsonl"
rm -rf "$dir/.tmp"
echo "fixture ready: $dir"
