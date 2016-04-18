#!/bin/sh
set -e

echo "Installing binary..."
install -d $DESTDIR/usr/bin
install build/appstream-generator $DESTDIR/usr/bin

echo "Installing data..."
install -d $DESTDIR/usr/share/appstream
install data/asgen-hints.json $DESTDIR/usr/share/appstream

install -d $DESTDIR/usr/share/appstream/templates
cp -dru data/templates/* -t $DESTDIR/usr/share/appstream/templates

echo "Done."
