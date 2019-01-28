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
import std.string : format, strip, startsWith;
import std.array : empty;
import std.conv : to;
import std.parallelism : parallel;
import appstream.Component : Component, ComponentKind;
import appstream.Translation : Translation, TranslationKind;

import containers: HashMap;
import asgen.logging;
import asgen.result : GeneratorResult;
import asgen.backends.interfaces : Package;


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

auto getDataForFile (GeneratorResult gres, Package pkg, Component cpt, const string fname)
{
    if (pkg is null)
        pkg = gres.pkg;
    const(ubyte)[] fdata;
    try {
        fdata = pkg.getFileData (fname);
    } catch (Exception e) {
        gres.addHint (cpt, "pkg-extract-error", ["fname": fname.baseName,
                                                  "pkg_fname": pkg.getFilename.baseName,
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
 * Finds localization in a set of packages and allows extracting
 * translation statistics from locale.
 */
public final class LocaleHandler
{

private:
    HashMap!(string, Package) localeIdPkgMap;

    public this (Package[] pkgList)
    {
        import std.typecons : scoped;
        import asgen.contentsstore : ContentsStore;
        import asgen.config : Config;

        logDebug ("Creating new LocaleHandler.");

        // convert the list into a HashMap for faster lookups
        auto pkgMap = HashMap!(string, Package) (64);
        foreach (ref pkg; pkgList) {
            immutable pkid = pkg.id;
            pkgMap[pkid] = pkg;
        }

        localeIdPkgMap = HashMap!(string, Package) (64);

        auto conf = Config.get;
        if (!conf.feature.processLocale)
            return; // don't load the expensive locale<->package mapping if we don't need it

        // open package contents cache
        auto ccache = scoped!ContentsStore ();
        ccache.open (conf);

        // we make the assumption here that all locale for a given domain are in one package.
        // otherwise this global search will get even more insane.
        foreach (info; parallel (ccache.getContentsMap (pkgMap.keys).byKeyValue, 100)) {
            immutable fname = info.key;
            immutable pkgid = info.value;

            if (!fname.startsWith ("/usr/share/locale/"))
                continue;
            immutable id = fname.baseName;

            // check if we already have a package - lookups in this HashMap are faster
            // due to its smaller size and (most of the time) outweight the following additional
            // lookup for the right package entity.
            synchronized (this) {
                if (localeIdPkgMap.get (id, null) !is null)
                    continue;
            }

            Package pkg;
            if (pkgid !is null)
                pkg = pkgMap.get (pkgid, null);

            if (pkg !is null) {
                synchronized (this) localeIdPkgMap[id] = pkg;
            }
        }

        logDebug ("Created new LocaleHandler.");
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
        string[] gettextDomains;
        auto translationsArr = cpt.getTranslations;
        if (translationsArr.len > 0) {
            import appstream.c.types : AsTranslation;

            for (uint i = 0; i < translationsArr.len; i++) {
                // cast array data to D Screenshot and keep a reference to the C struct
                auto tr = new Translation (cast (AsTranslation*) translationsArr.index (i));
                if (tr.getKind == TranslationKind.GETTEXT)
                    gettextDomains ~= tr.getId.strip;
            }

            translationsArr.removeRange (0, translationsArr.len);
        }

        // exit if we have no Gettext domains specified
        if (gettextDomains.empty)
            return;

        ulong maxNStrings = 0;
        auto localeMap = HashMap!(string, ulong) (32);

        // Process Gettext .mo files for information
        foreach (ref domain; gettextDomains) {
            auto pkg = localeIdPkgMap.get ("%s.mo".format (domain), null);
            if (pkg is null) {
                gres.addHint (cpt, "gettext-data-not-found", ["domain": domain]);
                continue;
            }

            foreach (ref fname; pkg.contents) {
                if (!fname.globMatch ("/usr/share/locale/*/LC_MESSAGES/%s.mo".format (domain)))
                    continue;
                auto data = getDataForFile (gres, pkg, cpt, fname);
                if (data.empty)
                    continue;
                immutable locale = fname.split ("/")[4];
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

        // by this point we should have at least some locale information.
        // if that is not the case, warn about it.
        if (localeMap.empty) {
            gres.addHint (cpt, "no-translation-statistics");
            return;
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
