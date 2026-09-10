#!/bin/sh
# Install the goldenspiral layout and its app bar. Idempotent: safe to re-run
# after a git pull (everything is symlinked, so a pull updates in place).
set -eu

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hypr"
bin_dir="$HOME/.local/bin"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/goldenspiral"

mkdir -p "$hypr_dir" "$bin_dir" "$cfg_dir"

ln -sfn "$src/goldenspiral.lua" "$hypr_dir/goldenspiral.lua"
echo "linked $hypr_dir/goldenspiral.lua -> $src/goldenspiral.lua"

ln -sfn "$src/bar/chronobar.py" "$bin_dir/goldenspiral-bar"
chmod +x "$src/bar/chronobar.py"
echo "linked $bin_dir/goldenspiral-bar -> $src/bar/chronobar.py"

if [ ! -e "$cfg_dir/bar.json" ]; then
    cp "$src/bar/bar.example.json" "$cfg_dir/bar.json"
    echo "wrote $cfg_dir/bar.json (starter, edit to taste)"
else
    echo "kept existing $cfg_dir/bar.json"
fi

cat <<'NEXT'

Add to your Hyprland Lua config (after whatever sets general:layout):

    require("hypr.goldenspiral")

Then:

    hyprctl reload
    hyprctl configerrors        # expect no output

The layout registers itself, binds its controls, adds a window rule for the
bar, and (where hl.on is available) launches `goldenspiral-bar` at session
start. Make sure ~/.local/bin is on your PATH, or start it once by hand:

    goldenspiral-bar &

Requires: python (with PyGObject and GTK 4).
NEXT
