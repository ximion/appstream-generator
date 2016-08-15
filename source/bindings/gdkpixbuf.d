/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This library is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the license, or
 * (at your option) any later version.
 *
 * This software is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 */

module bindings.gdkpixbuf;

import gi.glibtypes;
import gi.giotypes;
import bindings.cairo;

extern(C):
nothrow:
@nogc:

enum GdkInterpType {
	NEAREST,
	TILES,
	BILINEAR,
	HYPER
};

struct _GdkPixbuf {}
alias GdkPixbuf = _GdkPixbuf*;

GdkPixbuf gdk_pixbuf_new_from_file (const(char) *filename, GError **error);
GdkPixbuf gdk_pixbuf_new_from_stream (GInputStream *stream, GCancellable *cancellable, GError **error);

int gdk_pixbuf_get_width (GdkPixbuf pixbuf);
int gdk_pixbuf_get_height (GdkPixbuf pixbuf);

GdkPixbuf gdk_pixbuf_scale_simple (const(GdkPixbuf) src, int dest_width, int dest_height, GdkInterpType interp_type);

bool gdk_pixbuf_save_to_buffer (GdkPixbuf pixbuf, char **buffer, size_t *buffer_size, const(char) *type, GError **error, ...);
bool gdk_pixbuf_save (GdkPixbuf pixbuf, const(char) *filename, const(char) *type, GError **error, ...);
