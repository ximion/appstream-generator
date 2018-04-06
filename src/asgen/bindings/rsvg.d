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

module asgen.bindings.rsvg;

import glib.c.types;
import asgen.bindings.cairo;

extern(C):
nothrow:
@nogc:

struct _RsvgHandle;
alias RsvgHandle = _RsvgHandle*;

struct RsvgDimensionData {
    int width;
    int height;
    double em;
    double ex;
}

RsvgHandle rsvg_handle_new ();
void g_object_unref (void* object);

bool rsvg_handle_write (RsvgHandle handle, const(ubyte) *buf, long count, GError **error);
bool rsvg_handle_close (RsvgHandle handle, GError **error);
void rsvg_handle_get_dimensions (RsvgHandle handle, RsvgDimensionData *dimension_data);

bool rsvg_handle_render_cairo (RsvgHandle handle, cairo_p cr);
