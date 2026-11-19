#!/bin/sh
# Renders the favicons, app icons and the Open Graph image in public/ from the SVGs in design/
# and public/seatbay-icon.svg. The PNGs are committed, so this only needs to run when the artwork
# changes. Needs rsvg-convert (librsvg) and ImageMagick (`magick`); the OG image text uses
# Helvetica Neue, so render it on a Mac for the intended look.
set -eu
cd "$(dirname "$0")/.."

icon=public/seatbay-icon.svg

rsvg-convert -w 1200 -h 630 design/og-image.svg -o public/og-image.png
rsvg-convert -w 512 -h 512 "$icon" -o public/icon-512.png
rsvg-convert -w 192 -h 192 "$icon" -o public/icon-192.png
rsvg-convert -w 180 -h 180 design/apple-touch-icon.svg -o public/apple-touch-icon.png
rsvg-convert -w 32 -h 32 design/favicon.svg -o public/favicon-32.png
rsvg-convert -w 16 -h 16 design/favicon.svg -o public/favicon-16.png
cp design/favicon.svg public/favicon.svg

tmp=$(mktemp -d)
rsvg-convert -w 48 -h 48 design/favicon.svg -o "$tmp/favicon-48.png"
magick public/favicon-16.png public/favicon-32.png "$tmp/favicon-48.png" public/favicon.ico
rm -rf "$tmp"

echo "rendered: og-image.png icon-512.png icon-192.png apple-touch-icon.png favicon-32.png favicon-16.png favicon.ico"
