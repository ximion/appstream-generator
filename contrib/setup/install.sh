#!/bin/sh
set -e

echo "Installing binary..."
install -d $DESTDIR/usr/bin
install build/appstream-generator $DESTDIR/usr/bin

echo "Installing data..."
install -d $DESTDIR/usr/share/appstream
install -m 0644 data/asgen-hints.json $DESTDIR/usr/share/appstream
install -m 0644 data/hicolor-theme-index.theme $DESTDIR/usr/share/appstream

install -d $DESTDIR/usr/share/appstream/templates
cp -dpru --no-preserve=ownership data/templates/* -t $DESTDIR/usr/share/appstream/templates

echo "Done."
