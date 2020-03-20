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

module asgen.bindings.gdkpixbuf;

import glib.c.types;
import gio.c.types;
import asgen.bindings.cairo;

@nogc nothrow
extern(C) {

enum GdkInterpType {
    NEAREST,
    TILES,
    BILINEAR,
    HYPER
}

struct _GdkPixbuf {}
alias GdkPixbuf = _GdkPixbuf*;

GdkPixbuf gdk_pixbuf_new_from_file (const(char) *filename, GError **error);
GdkPixbuf gdk_pixbuf_new_from_stream (GInputStream *stream, GCancellable *cancellable, GError **error);

int gdk_pixbuf_get_width (GdkPixbuf pixbuf);
int gdk_pixbuf_get_height (GdkPixbuf pixbuf);

GdkPixbuf gdk_pixbuf_scale_simple (const(GdkPixbuf) src, int dest_width, int dest_height, GdkInterpType interp_type);

bool gdk_pixbuf_save_to_buffer (GdkPixbuf pixbuf, char **buffer, size_t *buffer_size, const(char) *type, GError **error, ...);
bool gdk_pixbuf_save (GdkPixbuf pixbuf, const(char) *filename, const(char) *type, GError **error, ...);

private GSList* gdk_pixbuf_get_formats ();
private const(char) *gdk_pixbuf_format_get_name (void *);

} // end of extern:C

/**
 * Get a set of image format names GdkPixbuf
 * currently supports.
 */
public auto gdkPixbufGetFormatNames () @trusted
{
    import glib.Str : Str;
    import glib.c.functions : g_slist_free;

    bool[string] res;
    auto fmList = gdk_pixbuf_get_formats ();
    if(fmList is null)
        return res;

    auto list = fmList;
    while (list !is null) {
        immutable formatName = Str.toString(cast(char*) gdk_pixbuf_format_get_name (list.data));
        res[formatName] = true;
        list = list.next;
    }

    g_slist_free (fmList);
    return res;
}
