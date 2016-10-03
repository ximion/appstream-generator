#!/bin/sh
set -e

cd "$MESON_SOURCE_ROOT"

echo "Installing templates..."
install -d "${DESTDIR}/${MESON_INSTALL_PREFIX}/share/appstream/templates"
cp -dpru --no-preserve=ownership data/templates/* -t "${DESTDIR}/${MESON_INSTALL_PREFIX}/share/appstream/templates"
