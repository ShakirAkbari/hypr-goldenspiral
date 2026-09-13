#!/bin/sh
# Install the goldenspiral layout. Idempotent: safe to re-run after a git pull
# (the layout is symlinked, so a pull updates it in place).
set -eu

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hypr"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/goldenspiral"

mkdir -p "$hypr_dir" "$cfg_dir"

ln -sfn "$src/goldenspiral.lua" "$hypr_dir/goldenspiral.lua"
echo "linked $hypr_dir/goldenspiral.lua -> $src/goldenspiral.lua"

cat <<'NEXT'

Add to your Hyprland Lua config (after whatever sets general:layout):

    require("hypr.goldenspiral")

Then:

    hyprctl reload
    hyprctl configerrors        # expect no output

The layout registers itself and binds its controls. It has no bar of its own:
install github.com/ShakirAkbari/hypr-chronobar separately for the corner
dock, and goldenspiral will automatically keep tiles out of its way (it reads
the bar's published geometry, no configuration needed on this side).
NEXT
