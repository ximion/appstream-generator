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

import std.string : format, fromStringz, toStringz, toLower, strip;
import std.conv : to;
import std.path : buildPath, baseName;
import std.array : empty, appender, replace;
import std.algorithm : countUntil, remove;
static import std.file;

import asgen.bindings.freetype;
import asgen.bindings.fontconfig;
import asgen.bindings.pango;

import asgen.logging;
import asgen.config : Config;


// NOTE: The font's full-name (and the family-style combo we use if the full name is unavailable), can be
// determined on the command-line via:
// fc-query --format='FN: %{fullname}\nFS: %{family[0]} %{style[0]}\n' <fontfile>

private static __gshared string[string] iconTexts;

// initialize module static data
shared static this ()
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

    string style_;
    string fullname_;

    immutable string fileBaseName;

public:

    this (string fname)
    {
        // NOTE: Freetype is completely non-threadsafe, but we only use it in the constructor.
        // So mark this section of code as synchronized to never run it in parallel (even having
        // two Font objects constructed in parallel may lead to errors)
        synchronized {
            initFreeType ();

            FT_Error err;
            err = FT_New_Face (library, fname.toStringz (), 0, &fface);
            if (err != 0)
                throw new Exception ("Unable to load font face from file. Error code: %s".format (err));

                loadFontConfigData (fname);
                fileBaseName = fname.baseName;
        }
    }

    this (const(ubyte)[] data, string fileBaseName)
    {
        import std.stdio : File;

        // we unfortunately need to create a stupid temporary file here, otherwise Fontconfig
        // does not work and we can not determine the right demo strings for this font.
        // (FreeType itself could load from memory)
        immutable tmpRoot = Config.get ().getTmpDir;
        std.file.mkdirRecurse (tmpRoot);
        immutable fname = buildPath (tmpRoot, fileBaseName);
        auto f = File (fname, "w");
        f.rawWrite (data);
        f.close ();

        this (fname);
    }

    ~this ()
    {
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

    private bool ready () const
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
        // open FC font patter
        // the count pointer has to be valid, otherwise FcFreeTypeQuery() crashes.
        int c;
        auto fpattern = FcFreeTypeQuery (fname.toStringz, 0, null, &c);
        scope (exit) FcPatternDestroy (fpattern);

        // load information about the font
        auto res = appender!(string[]);

        auto anyLangAdded = false;
        auto match = true;
        for (uint i = 0; match == true; i++) {
            FcLangSet *ls;

            match = false;
            if (FcPatternGetLangSet (fpattern, FC_LANG, i, &ls) == FcResult.Match) {
                match = true;
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
                    anyLangAdded = true;
                }
            }
        }

        char *fullNameVal;
        if (FcPatternGetString (fpattern, FC_FULLNAME, 0, &fullNameVal) == FcResult.Match) {
            fullname_ = fullNameVal.fromStringz.dup;
        }

        char *styleVal;
        if (FcPatternGetString (fpattern, FC_STYLE, 0, &styleVal) == FcResult.Match) {
            style_ = styleVal.fromStringz.dup;
        }

        // assume 'en' is available
        if (!anyLangAdded)
            res ~= "en";
        languages_ = res.data;

        // prefer the English language if possible
        // this is a hack since some people don't set their
        // <languages> tag properly.
        immutable enIndex = languages_.countUntil ("en");
        if (anyLangAdded && enIndex > 0) {
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
        return style_;
    }

    @property
    string fullName ()
    {
        if (fullname_.empty)
            return "%s %s".format (family, style);
        else
            return fullname_;
    }

    @property
    string id ()
    {
        import std.string;

        if (this.family is null)
            return fileBaseName;
        if (this.style is null)
            return fileBaseName;
        return "%s-%s".format (this.family.strip.toLower.replace (" ", ""),
                               this.style.strip.toLower.replace (" ", ""));
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
    const(FT_Face) fontFace () const
    {
        assert (ready ());
        return fface;
    }

    @property
    const(string[]) languages () const
    {
        return languages_;
    }

    private void findSampleTexts ()
    {
        assert (ready ());
        import std.uni : byGrapheme, isGraphical, byCodePoint, Grapheme;
        import std.range;

        void setFallbackSampleTextIfRequired ()
        {
            if (sampleText_.empty)
                sampleText_ = "Lorem ipsum dolor sit amet, consetetur sadipscing elitr.";

            if (sampleIconText_.empty) {
                import std.conv : text;

                auto graphemes = sampleText_.byGrapheme;
                if (graphemes.walkLength > 3)
                    sampleIconText_ = graphemes.array[0..3].byCodePoint.text;
                else
                    sampleIconText_ = "Aa";
            }
        }

        dchar getFirstUnichar (string str)
        {
            auto g = Grapheme (str);
            return g[0];
        }

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
        setFallbackSampleTextIfRequired ();

        // check if we have a font that can actually display the characters we picked - in case
        // it doesn't, we just select random chars.
        if (FT_Get_Char_Index (fface, getFirstUnichar (sampleIconText_)) == 0) {
            sampleText_ = "☃❤✓☀★☂♞☯☢∞❄♫↺";
            sampleIconText_ = "☃❤";
        }
        if (FT_Get_Char_Index (fface, getFirstUnichar (sampleIconText_)) == 0) {
            import std.uni;
            import std.utf : toUTF8;

            sampleText_ = "";
            sampleIconText_ = "";

            auto count = 0;
            for (uint map = 0; map < fface.num_charmaps; map++) {
                auto charmap = fface.charmaps[map];

                FT_Set_Charmap (fface, charmap);

                FT_UInt gindex;
                auto charcode = FT_Get_First_Char (fface, &gindex);
                while (gindex != 0) {
                    immutable chc = to!dchar (charcode);
                    if (chc.isGraphical && !chc.isSpace && !chc.isPunctuation) {
                        count++;
                        sampleText_ ~= chc;
                    }

                    if (count >= 24)
                        break;
                    charcode = FT_Get_Next_Char (fface, charcode, &gindex);
                }

                if (count >= 24)
                    break;
            }

            sampleText_ = sampleText_.strip;

            // if we were unsuccessful at adding chars, set fallback again
            // (and in this case, also set the icon text to something useful again)
            setFallbackSampleTextIfRequired ();
        }
    }

    @property
    string sampleText ()
    {
        if (sampleText_.empty)
            findSampleTexts ();
        return sampleText_;
    }

    @property
    void sampleText (string val)
    {
        if (val.length > 2)
            sampleText_ = val;
    }

    @property
    string sampleIconText ()
    {
        if (sampleIconText_.empty)
            findSampleTexts ();
        return sampleIconText_;
    }

    @property
    void sampleIconText (string val)
    {
        if (val.length <= 3)
            sampleIconText_ = val;
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
