#!/bin/sh
set -e

if [ -n "$MESON_SOURCE_ROOT" ]; then
    cd "$MESON_SOURCE_ROOT/contrib/setup/"
fi

YARNPKG="yarn"
if [ ! -z "$1" ]
then
    YARNPKG=$1
fi

$YARNPKG install --no-bin-links --prod --no-lockfile --non-interactive

JS_TARGET=../../data/templates/default/static/js
[ ! -d "$JS_TARGET" ] && mkdir $JS_TARGET

[ ! -d "$JS_TARGET/jquery" ] && mkdir $JS_TARGET/jquery
install node_modules/jquery/dist/*.min.js -t $JS_TARGET/jquery

[ ! -d "$JS_TARGET/flot" ] && mkdir $JS_TARGET/flot
install node_modules/jquery-flot/jquery.flot*.js -t $JS_TARGET/flot

[ ! -d "$JS_TARGET/highlight" ] && mkdir $JS_TARGET/highlight
install node_modules/highlightjs/*.js -t $JS_TARGET/highlight
