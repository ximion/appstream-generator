#!/bin/sh
set -e

bower install d3 rickshaw highlightjs

JS_TARGET=../../data/templates/default/static/js

[ ! -d "$JS_TARGET/d3" ] && mkdir $JS_TARGET/d3
install js_tmp/d3/*.js -t $JS_TARGET/d3

[ ! -d "$JS_TARGET/rickshaw" ] && mkdir $JS_TARGET/rickshaw
install js_tmp/rickshaw/*.js -t $JS_TARGET/rickshaw

[ ! -d "$JS_TARGET/highlight" ] && mkdir $JS_TARGET/highlight
install js_tmp/highlightjs/*.js -t $JS_TARGET/highlight
