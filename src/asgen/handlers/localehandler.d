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

import std.string : format;
import std.conv : to;

import glib.PtrArray : PtrArray;
import glib.c.types : GQuark, GError, GBytes;

import appstream.Component : Component, ComponentKind;
import appstream.Translation : Translation, TranslationKind;

import ascompose.Unit : Unit;
import ascompose.TranslationUtils : TranslationUtils;
import ascompose.c.types : AscUnit;

import asgen.logging;
import asgen.config : Config;
import asgen.result : GeneratorResult;
import asgen.contentsstore : ContentsStore;
import asgen.backends.interfaces : Package;


private __gshared extern(C) GQuark asc_compose_error_quark ();

private final class LocaleHandlerUnit : Unit
{
    package Package[string] localeFilePkgMap;

    auto getClass ()
    {
        import gobject.c.types : GTypeInstance;
        import ascompose.c.types : AscUnitClass;
        return cast(AscUnitClass*) (cast(GTypeInstance*) ascUnit).gClass;
    }

    public this (ContentsStore cstore, Package[] pkgList)
    {
        import std.array : array;
        import std.typecons : scoped;
        import std.string : toStringz;
        import glib.c.functions : g_strdup, g_free;

        // helper for function override callbacks
        setUserData (cast(void*) this);

        // convert the list into an associative array for faster lookups
        Package[string] pkgMap;
        foreach (ref pkg; pkgList) {
            immutable pkid = pkg.id;
            pkgMap[pkid] = pkg;
        }
        pkgMap.rehash ();

        auto conf = Config.get;
        if (!conf.feature.processLocale)
            return; // don't load the expensive locale<->package mapping if we don't need it

        // we make the assumption here that all locale for a given domain are in one package.
        // otherwise this global search will get even more insane.
        // the key of the map returned by getLocaleMap will therefore contain only the locale
        // file basename instead of a full path
        auto dbLocaleMap = cstore.getLocaleMap (array(pkgMap.byKey));
        foreach (ref info; dbLocaleMap.byKeyValue) {
            immutable id = info.key;
            immutable pkgid = info.value;

            // check if we already have a package - lookups in this HashMap are faster
            // due to its smaller size and (most of the time) outweight the following additional
            // lookup for the right package entity.
            if (localeFilePkgMap.get (id, null) !is null)
                continue;

            Package pkg;
            if (pkgid !is null)
                pkg = pkgMap.get (pkgid, null);

            if (pkg !is null)
                localeFilePkgMap[id] = pkg;
        }

        auto contents = new PtrArray (&g_free);
        foreach (ref fname; localeFilePkgMap.byKey)
            contents.add (cast(void*) g_strdup (fname.toStringz));
        setContents (contents);

        auto klass = getClass ();
        klass.open = &LocaleHandlerUnit.c_open;
        klass.close = &LocaleHandlerUnit.c_close;
        klass.fileExists = &LocaleHandlerUnit.c_fileExists;
        klass.dirExists = &LocaleHandlerUnit.c_dirExists;
        klass.readData = &LocaleHandlerUnit.readData;
    }

    public override bool open ()
    {
        // we already opened everything in the constructor
        // (this enables us to reuse this fake unit multiple times)
        return c_open (ascUnit, null) > 0;
    }

    public override void close ()
    {
        c_close (ascUnit);
    }

	private static extern(C) int c_open (AscUnit* unit, GError** err)
	{
	    return 1;
    }

	private static extern(C) void c_close (AscUnit* unit)
	{
	    //  noop
	}

	private static extern(C) int c_fileExists (AscUnit* unit, const(char)* filename)
	{
	    import std.string : fromStringz;
	    import ascompose.c.functions : asc_unit_get_user_data;

	    auto self = cast(LocaleHandlerUnit) asc_unit_get_user_data (unit);
	    return ((filename.fromStringz in self.localeFilePkgMap) is null)? 0 : 1;
	}

	private static extern(C) int c_dirExists (AscUnit* unit, const(char)* dirname)
	{
	    // not implemented yet, as it's not needed for locale finding (yet?)
		return 0;
    }

	private static extern(C) GBytes *readData (AscUnit* unit, const(char)* filename, GError** err)
	{
	    import glib.c.functions : g_bytes_new_take, g_memdup, g_set_error_literal;
	    import ascompose.c.types : ComposeError;
	    import ascompose.c.functions : asc_unit_get_user_data;
	    import std.string : toStringz, fromStringz;

	    auto self = cast(LocaleHandlerUnit) asc_unit_get_user_data (unit);
	    const fname = filename.fromStringz.to!string;

	    auto pkgP = fname in self.localeFilePkgMap;
		if (pkgP is null) {
		    g_set_error_literal (err,
                                 asc_compose_error_quark,
                                 ComposeError.FAILED,
                                 toStringz ("File '%s' does not exist in a known package!".format(fname)));
			return null;
        }
		const data = cast(ubyte[]) (*pkgP).getFileData (fname);

        // FIXME: We should use g_memdup2 here, once we can bump the GLib version!
        void *ncCopy = g_memdup (cast(void*) data.ptr, cast(uint) data.length);
        return g_bytes_new_take (ncCopy, cast(size_t) data.length);
	}
}

/**
 * Finds localization in a set of packages and allows extracting
 * translation statistics from locale.
 */
public final class LocaleHandler
{

private:
    LocaleHandlerUnit lhUnit;
    Config config;

    public this (ContentsStore cstore, Package[] pkgList)
    {
        logDebug ("Creating new LocaleHandler.");
        config = Config.get;
        lhUnit = new LocaleHandlerUnit (cstore, pkgList);
        lhUnit.open();
        logDebug ("Created new LocaleHandler.");
    }

    /**
    * Load localization information for the given component.
    */
    public void processLocaleInfoForComponent (GeneratorResult gres, Component cpt)
    {
        if (!config.feature.processLocale)
            return;
        TranslationUtils.readTranslationStatus(gres,
                                               lhUnit,
                                               "/usr",
                                               25);
    }
}
