#!/bin/sh
set -eu
ditoo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ditoo_prefix=${PREFIX:-"$HOME/.local"}
if [ "$#" -gt 1 ]; then
  echo 'Usage: install.sh [PREFIX] (default: ~/.local)' >&2
  exit 2
fi
if [ "$#" -eq 1 ]; then ditoo_prefix=$1; fi
case "$ditoo_prefix" in /*) ;; *) echo 'PREFIX must be absolute.' >&2; exit 2 ;; esac
if [ -x "$ditoo_root/bin/ditooctl" ]; then
  ditoo_binary="$ditoo_root/bin/ditooctl"
else
  swift build --package-path "$ditoo_root" -c release --product ditooctl >&2
  ditoo_build=$(swift build --package-path "$ditoo_root" -c release --show-bin-path)
  ditoo_binary="$ditoo_build/ditooctl"
fi
mkdir -p "$ditoo_prefix/bin"
ditoo_temp=$(mktemp "$ditoo_prefix/bin/.ditooctl.XXXXXX")
trap 'rm -f "$ditoo_temp"' EXIT HUP INT TERM
install -m 755 "$ditoo_binary" "$ditoo_temp"
mv -f "$ditoo_temp" "$ditoo_prefix/bin/ditooctl"
echo "Installed $ditoo_prefix/bin/ditooctl"
"$ditoo_prefix/bin/ditooctl" --version
