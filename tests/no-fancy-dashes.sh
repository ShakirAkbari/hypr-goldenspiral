#!/bin/sh
# goldenspiral's prose and comments use plain ASCII punctuation only.
# Fail if any tracked file contains an em dash (U+2014) or en dash (U+2013);
# use '-', ',', ':' or '(...)' instead.
set -eu

if git grep -nP '[\x{2013}\x{2014}]'; then
  echo
  echo "^ em/en dashes in tracked files. Replace with '-', ',', ':' or '(...)'."
  exit 1
fi

echo "OK: no em/en dashes in tracked files."
