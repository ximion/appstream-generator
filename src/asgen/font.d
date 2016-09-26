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

module asgen.font;

import std.string : format, fromStringz, toStringz, toLower;
import std.conv : to;
import std.path : buildPath, baseName;
import std.array : empty, appender;
import std.algorithm : countUntil, remove;
static import std.file;

import asgen.bindings.freetype;
import asgen.bindings.fontconfig;
import asgen.bindings.pango;

import asgen.logging;
import asgen.config : Config;


private static __gshared string[string] iconTexts;
private void initIconTextMap ()
{
    if (iconTexts.length != 0)
        return;
    synchronized
        iconTexts = ["en": "Aa",
                     "ar": "أب",
                     "as": "অআই",
                     "bn": "অআই",
                     "be": "Аа",
                     "bg": "Аа",
                     "cs": "Aa",
                     "da": "Aa",
                     "de": "Aa",
                     "es": "Aa",
                     "fr": "Aa",
                     "gu": "અબક",
                     "hi": "अआइ",
                     "he": "אב",
                     "it": "Aa",
                     "kn": "ಅಆಇ",
                     "ml": "ആഇ",
                     "ne": "अआइ",
                     "nl": "Aa",
                     "or": "ଅଆଇ",
                     "pa": "ਅਆਇ",
                     "pl": "ĄĘ",
                     "pt": "Aa",
                     "ru": "Аа",
                     "sv": "Åäö",
                     "ta": "அஆஇ",
                     "te": "అఆఇ",
                     "ua": "Аа",
                     "zh-tw": "漢"];
}

class Font
{

private:

    FT_Library library;
    FT_Face fface;

    string[] languages_;
    string sampleText_;
    string sampleIconText_;

public:

    this (string fname)
    {
        // Nothing is threadsafe
        synchronized {
            initFreeType ();

            FT_Error err;
            err = FT_New_Face (library, fname.toStringz (), 0, &fface);
            if (err != 0)
                throw new Exception ("Unable to load font face from file. Error code: %s".format (err));

            loadFontConfigData (fname);
        }
    }

    this (const(ubyte)[] data, string fileBaseName)
    {
        import std.stdio : File;

        // we unfortunately need to create a stupid temporary file here, otherwise Fontconfig
        // does not work and we can not determine the right demo strings for this font.
        // (FreeType itself could load from memory)
        auto cacheRoot = Config.get ().cacheRootDir;
        if (!std.file.exists (cacheRoot))
            cacheRoot = "/tmp/";
        immutable fname = buildPath (cacheRoot, fileBaseName);
        auto f = File (fname, "w");
        f.rawWrite (data);
        f.close ();

        this (fname);
    }

    ~this ()
    {
        // We need to do this in sync, because Fontconfig is completely non-threadsafe,
        // and FreeType has shown bad behavior as well.
        synchronized
            release ();
    }

    void release ()
    {
        if (fface !is null)
            FT_Done_Face (fface);
        if (library !is null)
            FT_Done_Library (library);

        fface = null;
        library = null;
    }

    private bool ready ()
    {
        return fface !is null && library !is null;
    }

    private void initFreeType ()
    {
        library = null;
        fface = null;
        FT_Error err;

        err = FT_Init_FreeType (&library);
        if (err != 0)
            throw new Exception ("Unable to load FreeType. Error code: %s".format (err));
    }

    private void loadFontConfigData (string fname)
    {
    	// create a new fontconfig configuration
    	auto fconfig = FcConfigCreate ();
        scope (exit) {
            FcConfigAppFontClear (fconfig);
            FcConfigDestroy (fconfig);
        }

    	// ensure that default configuration and fonts are not loaded
    	FcConfigSetCurrent (fconfig);

    	// add just this one font
    	FcConfigAppFontAddFile (fconfig, fname.toStringz);
    	auto fonts = FcConfigGetFonts (fconfig, FcSetName.Application);
    	if (fonts is null || fonts.fonts is null) {
    		throw new Exception ("FcConfigGetFonts failed (for %s)".format (fname.baseName));
    	}
    	auto fpattern = fonts.fonts[0];

        // initialize our icon-text map globally
        initIconTextMap ();

        // load supported locale
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
        languages_ = res.data;

        // prefer the English language if possible
        // this is a hack since some people don't set their
        // <languages> tag properly.
        immutable enIndex = languages_.countUntil ("en");
        if (anyAdded && enIndex > 0) {
            languages_ = languages_.remove (enIndex);
            languages_ = "en" ~ languages_;
        }
    }

    @property
    string family ()
    {
        assert (ready ());
        return to!string (fface.family_name.fromStringz);
    }

    @property
    string style ()
    {
        assert (ready ());
        return to!string (fface.style_name.fromStringz);
    }

    @property
    string id ()
    {
        import std.string;
        assert (ready ());

        if (this.family is null)
            return null;
        if (this.style is null)
            return null;
        return "%s-%s".format (this.family.strip.toLower, this.style.strip.toLower);
    }

    @property
    FT_Encoding charset ()
    {
        assert (ready ());
        if (fface.num_charmaps == 0)
            return FT_ENCODING_NONE;

        return fface.charmaps[0].encoding;
    }

    @property
    FT_Face fontFace ()
    {
        assert (ready ());
        return fface;
    }

    @property
    string[] languages ()
    {
        return languages_;
    }

    private void findSampleTexts ()
    {
        assert (ready ());

        // determine our sample texts
        foreach (ref lang; this.languages) {
            auto plang = pango_language_from_string (lang.toStringz);
            auto text = pango_language_get_sample_string (plang).fromStringz;

			if (text is null)
				continue;

            sampleText_ = text.dup;
            auto itP = lang in iconTexts;
            if (itP !is null) {
                sampleIconText_ = *itP;
                break;
            }
		}

        // set some default values if we have been unable to find any texts
        if (sampleIconText_.empty) {
            if (sampleText_.length > 3)
                sampleIconText_ = sampleText_[0..2];
            else
                sampleIconText_ = "Aa";
        }
        if (sampleText_.empty)
            sampleText_ = "Lorem ipsum dolor sit amet, consetetur sadipscing elitr.";
    }

    @property
    string sampleText ()
    {
        if (sampleText_.empty)
            findSampleTexts ();
        return sampleText_;
    }

    @property
    string sampleIconText ()
    {
        if (sampleIconText_.empty)
            findSampleTexts ();
        return sampleIconText_;
    }
}

unittest
{
    import std.stdio : writeln, File;
    import std.path : buildPath;
    import asgen.utils : getTestSamplesDir;
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

    writeln (font.languages);
    assert (font.languages == ["en", "aa", "ab", "af", "ak", "an", "ast", "av", "ay", "az-az", "ba", "be", "ber-dz", "bg", "bi", "bin", "bm", "br", "bs",
                               "bua", "ca", "ce", "ch", "chm", "co", "crh", "cs", "csb", "cu", "cv", "cy", "da", "de", "ee", "el", "eo", "es", "et", "eu",
                               "fat", "ff", "fi", "fil", "fj", "fo", "fr", "fur", "fy", "ga", "gd", "gl", "gn", "gv", "ha", "haw", "ho", "hr", "hsb", "ht",
                               "hu", "hz", "ia", "id", "ie", "ig", "ik", "io", "is", "it", "jv", "kaa", "kab", "ki", "kj", "kk", "kl", "kr", "ku-am", "ku-tr",
                               "kum", "kv", "kw", "kwm", "ky", "la", "lb", "lez", "lg", "li", "ln", "lt", "lv", "mg", "mh", "mi", "mk", "mn-mn", "mo", "ms", "mt",
                               "na", "nb", "nds", "ng", "nl", "nn", "no", "nr", "nso", "nv", "ny", "oc", "om", "os", "pap-an", "pap-aw", "pl", "pt", "qu", "quz",
                               "rm", "rn", "ro", "ru", "rw", "sah", "sc", "sco", "se", "sel", "sg", "sh", "shs", "sk", "sl", "sm", "sma", "smj", "smn", "sms", "sn",
                               "so", "sq", "sr", "ss", "st", "su", "sv", "sw", "tg", "tk", "tl", "tn", "to", "tr", "ts", "tt", "tw", "ty", "tyv", "uk", "uz", "ve",
                               "vi", "vo", "vot", "wa", "wen", "wo", "xh", "yap", "yo", "za", "zu"]);
}
