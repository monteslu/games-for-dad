#!/usr/bin/env bash
# Sync the shared cardtable lib + art into a cart's app/ directory.
# Usage: ./sync.sh ../jacksorbetter
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CART="$1"
[ -d "$CART/app" ] || { echo "no app/ in $CART" >&2; exit 1; }
mkdir -p "$CART/app/lib" "$CART/app/cards" "$CART/app/fonts" "$CART/app/sounds"
cp "$HERE"/lib/*.lua "$CART/app/lib/"
cp "$HERE"/assets/cards/*.png "$CART/app/cards/"
cp "$HERE"/assets/fonts/*.ttf "$CART/app/fonts/"
cp "$HERE"/assets/sounds/*.ogg "$CART/app/sounds/"
echo "synced cardtable -> $CART/app"
