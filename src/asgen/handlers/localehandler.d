/*
 * Copyright (C) 2018-2019 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.handlers.localehandler;
private:

import std.path : baseName, buildPath;
import std.uni : toLower;
import std.string : format, strip;
import std.array : empty;
import std.conv : to;
import appstream.Component : Component, ComponentKind;
import appstream.Translation : Translation, TranslationKind;

import containers: HashMap;
import asgen.result : GeneratorResult;


/**
 * The header of GetText .mo files.
 * NOTE: uint is unsigned 32bits in D
 */
extern(C) struct GettextHeader {
    uint magic;
	uint revision;
	uint nstrings;
	uint orig_tab_offset;
	uint trans_tab_offset;
	uint hash_tab_size;
	uint hash_tab_offset;
	uint n_sysdep_segments;
	uint sysdep_segments_offset;
	uint n_sysdep_strings;
	uint orig_sysdep_tab_offset;
	uint trans_sysdep_tab_offset;
}

auto getDataForFile (GeneratorResult gres, const string fname)
{
    const(ubyte)[] fdata;
    try {
        fdata = gres.pkg.getFileData (fname);
    } catch (Exception e) {
        gres.addHint (null, "pkg-extract-error", ["fname": fname.baseName,
                                                  "pkg_fname": gres.pkg.getFilename.baseName,
                                                  "error": e.msg]);
        return null;
    }

    return fdata;
}

long nstringsForGettextData (GeneratorResult gres, const string locale, const(ubyte)[] moData)
{
    import core.stdc.string : memcpy;
    import std.bitmanip : swapEndian;

    GettextHeader header;
	memcpy (&header, cast(void*) moData, GettextHeader.sizeof);

    bool swapped;
	if (header.magic == 0x950412de)
		swapped = false;
	else if (header.magic == 0xde120495)
		swapped = true;
	else {
		gres.addHint (null, "mo-file-error", ["locale": locale]);
        return -1;
	}

    long nstrings;
	if (swapped)
		nstrings = header.nstrings.swapEndian;
	else
		nstrings = header.nstrings;

    if (nstrings > 0)
        return nstrings -1;
    return 0;
}

/**
 * Load localization information for the given component.
 */
public void processLocaleInfoForComponent (GeneratorResult gres, Component cpt)
{
    import std.path : globMatch;
    import std.array : split;

    immutable ckind = cpt.getKind;

    // we only can extract locale for a set of component types
    // (others either don't store files or have to manually set which locale they support)
    if (ckind != ComponentKind.DESKTOP_APP &&
        ckind != ComponentKind.CONSOLE_APP &&
        ckind != ComponentKind.SERVICE)
        return;


    // read translation domain hints from metainfo data
    auto gettextMoName = "*";
    auto translationsArr = cpt.getTranslations;
    if (translationsArr.len > 0) {
        import appstream.c.types : AsTranslation;

        gettextMoName = null;
        for (uint i = 0; i < translationsArr.len; i++) {
            // cast array data to D Screenshot and keep a reference to the C struct
            auto tr = new Translation (cast (AsTranslation*) translationsArr.index (i));
            if (tr.getKind == TranslationKind.GETTEXT)
                gettextMoName = tr.getId.strip;
        }

        translationsArr.removeRange (0, translationsArr.len);
    }

    ulong maxNStrings = 0;
    auto localeMap = HashMap!(string, ulong) (32);
    foreach (ref fname; gres.pkg.contents) {

        if (!gettextMoName.empty) {
            // Process Gettext .mo files for information
            if (fname.globMatch ("/usr/share/locale/*/LC_MESSAGES/%s.mo".format (gettextMoName))) {
                auto data = getDataForFile (gres, fname);
                if (data.empty)
                    continue;
                immutable locale = fname.split ("/")[3];
                auto nstrings = nstringsForGettextData (gres, locale, data);
                // check if there was an error
                if (nstrings < 0)
                    continue;

                // we sum up all string counts from all translation domains
                if (localeMap.get (locale, 0) != 0)
                    nstrings += localeMap[locale];

                localeMap[locale] = nstrings;
                if (nstrings > maxNStrings)
                    maxNStrings = nstrings;
            }
        }
    }

    foreach (ref info; localeMap.byKeyValue) {
        immutable locale = info.key;
        immutable nstrings = info.value;

        immutable int percentage = (nstrings * 100 / maxNStrings).to!int;

        // we only add languages if the translation is more than 25% complete
        if (percentage > 25)
            cpt.addLanguage (locale, percentage);
    }
}

unittest {
    import std.stdio : writeln;
    import asgen.utils : getFileContents, getTestSamplesDir;
    import asgen.backends.dummy.dummypkg;

    writeln ("TEST: ", "Locale Handler");

    auto pkg = new DummyPackage ("foobar", "1.0", "amd64");
    auto gres = new GeneratorResult (pkg);

    immutable moFile1 = buildPath (getTestSamplesDir (), "mo", "de", "appstream.mo");
    auto data = getFileContents (moFile1);
    auto nstrings = nstringsForGettextData (gres, "de", data);
    assert (nstrings == 196);

    immutable moFile2 = buildPath (getTestSamplesDir (), "mo", "ja", "appstream.mo");
    data = getFileContents (moFile2);
    nstrings = nstringsForGettextData (gres, "ja", data);
    assert (nstrings == 156);
}
