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
import std.path : buildPath, baseName;
import std.array : empty, appender;
static import std.file;

import bindings.freetype;
import bindings.fontconfig;

import logging;
import config : Config;

class Font
{

private:

    FT_Library library;
    FT_Face fface;

    FcConfig *fconfig;
    FcPattern *fpattern;

    const(ubyte)[] fdata;

public:

    this (string fname)
    {
        initFreeType ();

        FT_Error err;
        err = FT_New_Face (library, fname.toStringz (), 0, &fface);
        if (err != 0)
            throw new Exception ("Unable to load font face from file. Error code: %s".format (err));

        loadFontConfig (fname);
    }

    this (const(ubyte)[] data, string fileBaseName)
    {
        import std.stdio : File;
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


        // we unfortunately need to create a stupid temporary file here, otherwise fontconfig
        // does not work and we can not determine the right demo strings for this font.
        auto cacheRoot = Config.get ().cacheRootDir;
        if (!std.file.exists (cacheRoot))
            cacheRoot = "/tmp/";
        immutable fname = buildPath (cacheRoot, fileBaseName);
        auto f = File (fname, "w");
        f.rawWrite (data);
        f.close ();

        loadFontConfig (fname);
    }

    ~this ()
    {
        if (fconfig !is null) {
            //FcConfigAppFontClear (fconfig); // FIXME: This crashes...
	        FcConfigDestroy (fconfig);
        }
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

    void loadFontConfig (string fname)
    {
    	// create a new fontconfig configuration
    	fconfig = FcConfigCreate ();

    	// ensure that default configuration and fonts are not loaded
    	FcConfigSetCurrent (fconfig);

    	// add just this one font
    	FcConfigAppFontAddFile (fconfig, fname.toStringz);
    	auto fonts = FcConfigGetFonts (fconfig, FcSetName.Application);
    	if (fonts is null || fonts.fonts is null) {
    		throw new Exception ("FcConfigGetFonts failed (for %s)".format (fname.baseName));
    	}
    	fpattern = fonts.fonts[0];
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

    string[] getLanguages ()
    {
        auto fcRc = FcResult.Match;
        FcValue fcValue;
        auto res = appender!(string[]);

        auto anyAdded = false;
        for (uint i = 0; fcRc == FcResult.Match; i++) {
            FcLangSet *ls;

            fcRc = FcPatternGetLangSet (fpattern, FC_LANG, i, &ls);
            if (fcRc == FcResult.Match) {
                auto langs = FcLangSetGetLangs (ls);
                auto list = FcStrListCreate (langs);
                scope (exit) {
                    FcStrListDone (list);
                    FcStrSetDestroy (langs);
                }

                char *tmp;
                FcStrListFirst (list);
                while ((tmp = FcStrListNext (list)) !is null) {
                    res ~= to!string (tmp.fromStringz);
                    anyAdded = true;
                }
            }
        }

        // assume 'en' is available
        if (!anyAdded)
            res ~= "en";
        return res.data;
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
    font = new Font (data, "test.ttf");
    assert (font.family == "Noto Sans");
    assert (font.style == "Regular");
    assert (font.charset == FT_ENCODING_UNICODE);

    assert (font.getLanguages == ["aa", "ab", "af", "ak", "an", "ast", "av", "ay", "az-az", "ba", "be", "ber-dz", "bg", "bi", "bin", "bm", "br", "bs", "bua",
                                  "ca", "ce", "ch", "chm", "co", "crh", "cs", "csb", "cu", "cv", "cy", "da", "de", "ee", "el", "en", "eo", "es", "et", "eu",
                                  "fat", "ff", "fi", "fil", "fj", "fo", "fr", "fur", "fy", "ga", "gd", "gl", "gn", "gv", "ha", "haw", "ho", "hr", "hsb", "ht",
                                  "hu", "hz", "ia", "id", "ie", "ig", "ik", "io", "is", "it", "jv", "kaa", "kab", "ki", "kj", "kk", "kl", "kr", "ku-am", "ku-tr",
                                  "kum", "kv", "kw", "kwm", "ky", "la", "lb", "lez", "lg", "li", "ln", "lt", "lv", "mg", "mh", "mi", "mk", "mn-mn", "mo", "ms", "mt",
                                  "na", "nb", "nds", "ng", "nl", "nn", "no", "nr", "nso", "nv", "ny", "oc", "om", "os", "pap-an", "pap-aw", "pl", "pt", "qu", "quz",
                                  "rm", "rn", "ro", "ru", "rw", "sah", "sc", "sco", "se", "sel", "sg", "sh", "shs", "sk", "sl", "sm", "sma", "smj", "smn", "sms", "sn",
                                  "so", "sq", "sr", "ss", "st", "su", "sv", "sw", "tg", "tk", "tl", "tn", "to", "tr", "ts", "tt", "tw", "ty", "tyv", "uk", "uz", "ve",
                                  "vi", "vo", "vot", "wa", "wen", "wo", "xh", "yap", "yo", "za", "zu"]);
}
