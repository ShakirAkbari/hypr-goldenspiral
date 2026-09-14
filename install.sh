#!/bin/sh
# Install the goldenspiral layout. Idempotent: safe to re-run after a git pull
# (the layout is symlinked, so a pull updates it in place).
set -eu

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
hypr_dir="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hypr"
cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/goldenspiral"
autostart_lua="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/autostart.lua"
projects_dir="$HOME/Projects"
chronobar_dir="$projects_dir/hypr-chronobar"
chronobar_autostart_line='o.exec_on_start("qs -c chronobar")'
# First hypr-chronobar commit that publishes ~/.cache/hypr-chronobar/geometry.json,
# the only thing this layout actually reads from it (see read_bar_geometry).
chronobar_min_ref="8b8b6e6"

mkdir -p "$hypr_dir" "$cfg_dir"

ln -sfn "$src/goldenspiral.lua" "$hypr_dir/goldenspiral.lua"
echo "linked $hypr_dir/goldenspiral.lua -> $src/goldenspiral.lua"

# The app bar (github.com/ShakirAkbari/hypr-chronobar) is a separate project,
# not vendored code, but goldenspiral's bottom-right carve only does anything
# useful once it's present and new enough to publish geometry.json. Treat it
# like any other dependency: install it if missing, update it if the checked
# out commit predates geometry.json support. Skipped gracefully if git isn't
# available, or if something other than a git checkout already occupies
# chronobar_dir (never overwritten).
if ! command -v git >/dev/null 2>&1; then
  echo "no git found, skipping hypr-chronobar (install it yourself: github.com/ShakirAkbari/hypr-chronobar)" >&2
elif [ -d "$chronobar_dir" ] && [ ! -d "$chronobar_dir/.git" ]; then
  echo "warning: $chronobar_dir exists but isn't a git checkout, leaving it alone" >&2
else
  if [ -d "$chronobar_dir/.git" ]; then
    if git -C "$chronobar_dir" merge-base --is-ancestor "$chronobar_min_ref" HEAD 2>/dev/null; then
      echo "hypr-chronobar already new enough"
    else
      echo "hypr-chronobar predates geometry.json support, updating"
      git -C "$chronobar_dir" pull --ff-only
    fi
  else
    echo "cloning hypr-chronobar"
    mkdir -p "$projects_dir"
    git clone https://github.com/ShakirAkbari/hypr-chronobar.git "$chronobar_dir"
  fi

  if [ -f "$chronobar_dir/install.sh" ]; then
    sh "$chronobar_dir/install.sh"
  fi

  if [ -f "$autostart_lua" ]; then
    if ! grep -qF "$chronobar_autostart_line" "$autostart_lua"; then
      printf '\n%s\n' "$chronobar_autostart_line" >> "$autostart_lua"
      echo "added chronobar autostart to $autostart_lua"
    fi
  else
    echo "warning: no $autostart_lua, add manually: $chronobar_autostart_line" >&2
  fi
fi

cat <<'NEXT'

Add to your Hyprland Lua config (after whatever sets general:layout):

    require("hypr.goldenspiral")

Then:

    hyprctl reload
    hyprctl configerrors        # expect no output

The layout registers itself and binds its controls. The app bar
(hypr-chronobar) is installed and autostarted above if git was available;
goldenspiral automatically keeps tiles out of its way either way (it reads
the bar's published geometry, no configuration needed on this side).
NEXT
