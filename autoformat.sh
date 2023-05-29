#!/usr/bin/env bash
set -e

BASEDIR=$(dirname "$0")
cd $BASEDIR

export DC=ldc2
dub fetch dfmt

exec dub run --compiler=ldc2 dfmt -- -i -c . src/
