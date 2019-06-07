/*
 * Copyright (C) 2016-2018 Matthias Klumpp <matthias@tenstral.net>
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

import std.string : format, fromStringz, toStringz, toLower, strip, splitLines;
import std.conv : to;
import std.path : buildPath, baseName;
import std.array : empty, appender, replace;
import std.algorithm : countUntil, remove;
static import std.file;

import asgen.containers : HashMap;
import asgen.bindings.freetype;
import asgen.bindings.fontconfig;
import asgen.bindings.pango;

import asgen.logging;
import asgen.config : Config;


// NOTE: The font's full-name (and the family-style combo we use if the full name is unavailable), can be
// determined on the command-line via:
// fc-query --format='FN: %{fullname}\nFS: %{family[0]} %{style[0]}\n' <fontfile>

// global font icon text lookup table, initialized by the constructor or Font and valid (and in memory)
// as long as the generator runs.
private static string[string] iconTexts;

private static string[] englishPangrams = import("pangrams/en.txt").splitLines ();

/**
 * Representation of a single font file.
 */
final class Font
{

private:

    FT_Library library;
    FT_Face fface;

    HashMap!(string, bool) _languages;
    string _preferredLanguage;
    string _sampleText;
    string _sampleIconText;

    string _style;
    string _fullname;

    string _description;
    string _designerName;
    string _homepage;

    immutable string fileBaseName;

public:

    this (string fname)
    {
        _languages.clear ();

        // NOTE: Freetype is completely non-threadsafe, but we only use it in the constructor.
        // So mark this section of code as synchronized to never run it in parallel (even having
        // two Font objects constructed in parallel may lead to errors)
        synchronized {
            // initialize the global font icon lookup table
            if (iconTexts.length == 0) {
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
        _languages.clear ();

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
                    _languages.put (to!string (tmp.fromStringz), true);
                    anyLangAdded = true;
                }
            }
        }

        char *fullNameVal;
        if (FcPatternGetString (fpattern, FC_FULLNAME, 0, &fullNameVal) == FcResult.Match) {
            _fullname = fullNameVal.fromStringz.dup;
        }

        char *styleVal;
        if (FcPatternGetString (fpattern, FC_STYLE, 0, &styleVal) == FcResult.Match) {
            _style = styleVal.fromStringz.dup;
        }

        // assume 'en' is available
        if (!anyLangAdded)
            _languages.put ("en", true);

        // prefer the English language if possible
        // this is a hack since some people don't set their
        // <languages> tag properly.
        if (anyLangAdded && _languages.contains ("en"))
            preferredLanguage = "en";

        // read font metadata, if any is there
        readSFNTData ();
    }

    private void readSFNTData ()
    {
        import glib.c.functions : g_convert, g_free;

        immutable namecount = FT_Get_Sfnt_Name_Count (fface);
        for (int index = 0; index < namecount; index++) {
            FT_SfntName sname;
            if (FT_Get_Sfnt_Name (fface, index, &sname) != 0)
                continue;

            // only handle unicode names for en_US
            if (!(sname.platform_id == TT_PLATFORM_MICROSOFT
                && sname.encoding_id == TT_MS_ID_UNICODE_CS
                && sname.language_id == TT_MS_LANGID_ENGLISH_UNITED_STATES))
                continue;

            char* val = g_convert(cast(char*) sname.string,
                                  sname.string_len,
                                  "UTF-8",
                                  "UTF-16BE",
                                  null,
                                  null,
                                  null);
            scope (exit) g_free (val);
            switch (sname.name_id) {
                case TT_NAME_ID_SAMPLE_TEXT:
                    this._sampleIconText = val.fromStringz.dup;
                    break;
                case TT_NAME_ID_DESCRIPTION:
                    this._description = val.fromStringz.dup;
                    break;
                case TT_NAME_ID_DESIGNER_URL:
                    this._homepage = val.fromStringz.dup;
                    break;
                case TT_NAME_ID_VENDOR_URL:
                    if (this._homepage.empty)
                        this._homepage = val.fromStringz.dup;
                    break;
                default:
                    break;
            }
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
        return _style;
    }

    @property
    string fullName ()
    {
        if (_fullname.empty)
            return "%s %s".format (family, style);
        else
            return _fullname;
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

    auto getLanguageList ()
    {
        import std.algorithm : sort;
        import std.array : array;

        return array (_languages.byKey).sort;
    }

    @property
    void preferredLanguage (string lang)
    {
        _preferredLanguage = lang;
    }

    @property
    string preferredLanguage ()
    {
        return _preferredLanguage;
    }

    void addLanguage (string lang)
    {
        _languages.put (lang, true);
    }

    @property
    string description ()
    {
        return _description;
    }

    @property
    string homepage ()
    {
        return _homepage;
    }

    private string randomEnglishPangram (const string tmpId)
    {
        import std.digest.crc : crc32Of;
        import std.conv : to;
        import std.bitmanip : peek;
        import std.range : take;

        import std.stdio : writeln;

        // we do want deterministic results here, so base the "random"
        // pangram on the font family / font base name
        immutable ubyte[4] hash = crc32Of (tmpId);
        immutable pangramIdx = hash.to!(ubyte[]).peek!uint % englishPangrams.length;

        return englishPangrams[pangramIdx];
    }

    private string randomEnglishPangram ()
    {
        auto tmpFontId = this.family;
        if (tmpFontId.empty)
            tmpFontId = this.fileBaseName;

        return randomEnglishPangram (tmpFontId);
    }

    private void findSampleTexts ()
    {
        assert (ready ());
        import std.uni : byGrapheme, isGraphical, byCodePoint, Grapheme;
        import std.range;

        void setFallbackSampleTextIfRequired ()
        {
            if (_sampleText.empty)
                _sampleText = "Lorem ipsum dolor sit amet, consetetur sadipscing elitr.";

            if (_sampleIconText.empty) {
                import std.conv : text;

                auto graphemes = _sampleText.byGrapheme;
                if (graphemes.walkLength > 3)
                    _sampleIconText = graphemes.array[0..3].byCodePoint.text;
                else
                    _sampleIconText = "Aa";
            }
        }

        dchar getFirstUnichar (string str)
        {
            auto g = Grapheme (str);
            return g[0];
        }

        // if we only have to set the icon text, try to do it!
        if (!_sampleText.empty)
            setFallbackSampleTextIfRequired ();
        if (!_sampleIconText.empty)
            return;

        // always prefer English (even if not alphabetically first)
        if (_languages.contains ("en"))
            preferredLanguage = "en";

        // ensure we try the preferred language first
        auto tmpLangList = array(getLanguageList ());
        if (!preferredLanguage.empty)
            tmpLangList = [this.preferredLanguage] ~ tmpLangList;

        // determine our sample texts
        foreach (ref lang; tmpLangList) {
            auto plang = pango_language_from_string (lang.toStringz);
            string text;
            if (lang == "en")
                text = randomEnglishPangram ();
            else
                text = pango_language_get_sample_string (plang).fromStringz.to!string;

            if (text.empty)
                continue;

            _sampleText = text;
            const itP = lang in iconTexts;
            if (itP !is null) {
                _sampleIconText = *itP;
                break;
            }
        }

        // set some default values if we have been unable to find any texts
        setFallbackSampleTextIfRequired ();

        // check if we have a font that can actually display the characters we picked - in case
        // it doesn't, we just select random chars.
        if (FT_Get_Char_Index (fface, getFirstUnichar (_sampleIconText)) == 0) {
            _sampleText = "☃❤✓☀★☂♞☯☢∞❄♫↺";
            _sampleIconText = "☃❤";
        }
        if (FT_Get_Char_Index (fface, getFirstUnichar (_sampleIconText)) == 0) {
            import std.uni;

            _sampleText = "";
            _sampleIconText = "";

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
                        _sampleText ~= chc;
                    }

                    if (count >= 24)
                        break;
                    charcode = FT_Get_Next_Char (fface, charcode, &gindex);
                }

                if (count >= 24)
                    break;
            }

            _sampleText = _sampleText.strip;

            // if we were unsuccessful at adding chars, set fallback again
            // (and in this case, also set the icon text to something useful again)
            setFallbackSampleTextIfRequired ();
        }
    }

    @property
    string sampleText ()
    {
        if (_sampleText.empty)
            findSampleTexts ();
        return _sampleText;
    }

    @property
    void sampleText (string val)
    {
        if (val.length > 2)
            _sampleText = val;
    }

    @property
    string sampleIconText ()
    {
        if (_sampleIconText.empty)
            findSampleTexts ();
        return _sampleIconText;
    }

    @property
    void sampleIconText (string val)
    {
        if (val.length <= 3)
            _sampleIconText = val;
    }
}

unittest
{
    import std.stdio : writeln, File;
    import std.path : buildPath;
    import std.array : array;
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
    assert (font.homepage == "http://www.monotype.com/studio");
    assert (font.description == "Data hinted. Designed by Monotype design team.");

    const langList = array (font.getLanguageList ());
    writeln (langList);
    assert (langList == ["aa", "ab", "af", "ak", "an", "ast", "av", "ay", "az-az", "ba", "be", "ber-dz", "bg", "bi", "bin",
                         "bm", "br", "bs", "bua", "ca", "ce", "ch", "chm", "co", "crh", "cs", "csb", "cu", "cv", "cy", "da",
                         "de", "ee", "el", "en", "eo", "es", "et", "eu", "fat", "ff", "fi", "fil", "fj", "fo", "fr", "fur",
                         "fy", "ga", "gd", "gl", "gn", "gv", "ha", "haw", "ho", "hr", "hsb", "ht", "hu", "hz", "ia", "id",
                         "ie", "ig", "ik", "io", "is", "it", "jv", "kaa", "kab", "ki", "kj", "kk", "kl", "kr", "ku-am",
                         "ku-tr", "kum", "kv", "kw", "kwm", "ky", "la", "lb", "lez", "lg", "li", "ln", "lt","lv", "mg", "mh",
                         "mi", "mk", "mn-mn", "mo", "ms", "mt", "na", "nb", "nds", "ng", "nl", "nn", "no", "nr", "nso", "nv",
                         "ny", "oc", "om", "os", "pap-an", "pap-aw", "pl", "pt", "qu", "quz", "rm", "rn", "ro", "ru", "rw",
                         "sah", "sc", "sco", "se", "sel", "sg", "sh", "shs", "sk", "sl", "sm","sma", "smj", "smn", "sms", "sn",
                         "so", "sq", "sr", "ss", "st", "su", "sv", "sw", "tg", "tk", "tl", "tn", "to", "tr", "ts", "tt", "tw",
                         "ty", "tyv", "uk", "uz", "ve", "vi", "vo", "vot", "wa", "wen", "wo", "xh", "yap", "yo", "za", "zu"]);


    // uses "Noto Sans"
    assert (font.randomEnglishPangram () == "A large fawn jumped quickly over white zebras in a box.");

    assert (font.randomEnglishPangram ("aaaaa") == "Jack amazed a few girls by dropping the antique onyx vase.");
    assert (font.randomEnglishPangram ("abcdefg") == "Two driven jocks help fax my big quiz.");
}
