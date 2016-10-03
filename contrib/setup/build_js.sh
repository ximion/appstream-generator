#!/bin/sh
set -e

if [ -n "$MESON_SOURCE_ROOT" ]; then
    cd "$MESON_SOURCE_ROOT/contrib/setup/"
fi

bower --allow-root install jquery jquery-flot highlightjs

JS_TARGET=../../data/templates/default/static/js
[ ! -d "$JS_TARGET" ] && mkdir $JS_TARGET

[ ! -d "$JS_TARGET/jquery" ] && mkdir $JS_TARGET/jquery
install js_tmp/jquery/dist/*.min.js -t $JS_TARGET/jquery

[ ! -d "$JS_TARGET/flot" ] && mkdir $JS_TARGET/flot
install js_tmp/Flot/jquery.flot*.js -t $JS_TARGET/flot

[ ! -d "$JS_TARGET/highlight" ] && mkdir $JS_TARGET/highlight
install js_tmp/highlightjs/*.js -t $JS_TARGET/highlight
