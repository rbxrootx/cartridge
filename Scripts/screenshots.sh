#!/bin/zsh
# Regenerates docs/*.png with a library of fictional games, in an isolated support folder
# (debug-only overrides; your real library, settings and name are never shown).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
swift build -c debug --product Cartridge >/dev/null
BIN="$(swift build -c debug --show-bin-path)/Cartridge"

# Fictional games: empty placeholder files with made-up title IDs. No real game names, data or artwork.
mkdir -p "$WORK/support" "$WORK/games"
i=1
for name in "Starlight Garden" "Pixel Rally" "Tiny Knights" "Moonlit Harbor" "Cloud Hopper"; do
  dir="$WORK/games/$name"; mkdir -p "$dir"
  head -c 1024 /dev/zero > "$dir/$name [05000000000${i}0000][v0].nsp"
  [[ $i == 1 ]] && head -c 1024 /dev/zero > "$dir/$name [05000000000${i}0800][v65536].nsp"
  [[ $i == 1 ]] && mkdir -p "$dir/$name.app/Contents/MacOS"   # shows the "Ready" state
  i=$((i + 1))
done
python3 - "$WORK" <<'PY'
import json, os, sys, uuid
work = sys.argv[1]
names = ["Starlight Garden", "Pixel Rally", "Tiny Knights", "Moonlit Harbor", "Cloud Hopper"]
games = [{"id": str(uuid.uuid4()).upper(), "folder": "file://" + os.path.join(work, "games", n).replace(" ", "%20") + "/", "added": 0} for n in names]
json.dump(games, open(os.path.join(work, "support", "library.json"), "w"))
PY

cat > "$WORK/winid.swift" <<'SWIFT'
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
if let w = list.first(where: { ($0["kCGWindowOwnerPID"] as? Int) == pid && ($0["kCGWindowLayer"] as? Int) == 0 }) {
    print(w["kCGWindowNumber"]!)
}
SWIFT
swiftc -O "$WORK/winid.swift" -o "$WORK/winid"

shot() { # shot <file> <appearance> <sheet>
  CARTRIDGE_DEBUG_SUPPORT="$WORK/support" CARTRIDGE_DEBUG_NAME="Player" CARTRIDGE_DEBUG_APPEARANCE="$2" \
    CARTRIDGE_DEBUG_SHEET="$3" "$BIN" >/dev/null 2>&1 &
  local pid=$!
  sleep 6
  screencapture -x -o -l "$("$WORK/winid" $pid)" "docs/$1.png"
  kill $pid; wait $pid 2>/dev/null || true
  echo "docs/$1.png"
}
shot home light ""
shot home-dark dark ""
shot setup light setup
shot game dark game
rm -rf "$WORK"
