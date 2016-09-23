/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This program is free software: you can redistribute it and/or modify
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
 * along with this software.  If not, see <http://www.gnu.org/licenses/>.
 */

import std.string : format, fromStringz, toStringz;
import std.conv : to;

import bindings.freetype;

import logging;
import config;

class Font
{

private:

    FT_Library library;
    FT_Face fface;

    const(ubyte)[] fdata;

public:

    this (string fname)
    {
        initFreeType ();

        FT_Error err;
        err = FT_New_Face (library, fname.toStringz (), 0, &fface);
        if (err != 0)
            throw new Exception ("Unable to load font face from file. Error code: %s".format (err));
    }

    this (const(ubyte)[] data)
    {
        initFreeType ();

        // we need to keep a reference, since FT doesn't copy
        // the data.
        fdata = data;

        FT_Error err;
        err = FT_New_Memory_Face (library,
                                  cast(ubyte*) fdata,
                                  ubyte.sizeof * fdata.length,
                                  0,
                                  &fface);
        if (err != 0)
            throw new Exception ("Unable to load font face from memory. Error code: %s".format (err));
    }

    ~this ()
    {
        if (fface !is null)
            FT_Done_Face (fface);
        if (library !is null)
            FT_Done_FreeType (library);
    }

    void initFreeType ()
    {
        library = null;
        fface = null;
        FT_Error err;

        err = FT_Init_FreeType (&library);
        if (err != 0)
            throw new Exception ("Unable to load FreeType. Error code: %s".format (err));
    }

    @property
    string family ()
    {
        return to!string (fface.family_name.fromStringz);
    }

    @property
    string style ()
    {
        return to!string (fface.style_name.fromStringz);
    }

    @property
    string id ()
    {
        import std.string;
        if (this.family is null)
            return null;
        if (this.style is null)
            return null;
        return "%s-%s".format (this.family.strip, this.style.strip);
    }

    @property
    FT_Encoding charset ()
    {
        if (fface.num_charmaps == 0)
            return FT_ENCODING_NONE;

        return fface.charmaps[0].encoding;
    }

    @property
    FT_Face fontFace ()
    {
        return fface;
    }
}

unittest
{
    import std.stdio : writeln, File;
    import std.path : buildPath;
    import utils : getTestSamplesDir;
    writeln ("TEST: ", "Font");

    immutable fontFile = buildPath (getTestSamplesDir (), "NotoSans-Regular.ttf");

    // test reading from file
    auto font = new Font (fontFile);
    assert (font.family == "Noto Sans");
    assert (font.style == "Regular");

    ubyte[] data;
    auto f = File (fontFile, "r");
    while (!f.eof) {
        char[512] buf;
        data ~= f.rawRead (buf);
    }

    // test reading from memory
    font = new Font (data);
    assert (font.family == "Noto Sans");
    assert (font.style == "Regular");
    assert (font.charset == FT_ENCODING_UNICODE);
}
