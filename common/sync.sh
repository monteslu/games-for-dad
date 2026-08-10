#!/usr/bin/env bash
# Sync the shared cardtable lib + art into a cart's app/ directory.
# Usage: ./sync.sh ../jacksorbetter
#        ./sync.sh --no-cards ../provinces   # cart draws its cards procedurally
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
COPY_CARDS=1
if [ "$1" = "--no-cards" ]; then COPY_CARDS=0; shift; fi
CART="$1"
[ -d "$CART/app" ] || { echo "no app/ in $CART" >&2; exit 1; }
mkdir -p "$CART/app/lib" "$CART/app/fonts" "$CART/app/sounds"
cp "$HERE"/lib/*.lua "$CART/app/lib/"
if [ "$COPY_CARDS" = 1 ]; then
  mkdir -p "$CART/app/cards"
  cp "$HERE"/assets/cards/*.png "$CART/app/cards/"
fi
cp "$HERE"/assets/fonts/*.ttf "$CART/app/fonts/"
cp "$HERE"/assets/sounds/*.ogg "$CART/app/sounds/"
echo "synced cardtable -> $CART/app"
