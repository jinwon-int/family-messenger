#!/bin/bash
# $1 svg  $2 out.png  $3 size  $4 transparent(0/1)
set -e
html=$(mktemp --suffix=.html); cp "$1" "/tmp/_icon_$$.svg"
printf '<html><body style="margin:0;background:transparent"><img src="file:///tmp/_icon_%s.svg" style="width:%spx;height:%spx;display:block"></body></html>' "$$" "$3" "$3" > "$html"
bg=""; [ "$4" = "1" ] && bg="--default-background-color=00000000"
google-chrome --headless=new --no-sandbox --disable-gpu --hide-scrollbars $bg --window-size=$3,$3 --screenshot="$2" "file://$html" >/dev/null 2>&1
rm -f "$html" "/tmp/_icon_$$.svg"
