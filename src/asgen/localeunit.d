/*
 * Copyright (C) 2018-2021 Matthias Klumpp <matthias@tenstral.net>
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

import std.conv : to;
import std.string : format;

import glib.PtrArray : PtrArray;
import glib.c.types : GQuark, GError, GBytes;

import ascompose.Unit : Unit;
import ascompose.c.types;

import asgen.config : Config;
import asgen.contentsstore : ContentsStore;
import asgen.backends.interfaces : Package;


private __gshared extern(C) GQuark asc_compose_error_quark ();

/**
 * Special unit that wraps the global locale fetching code.
 */
public final class LocaleUnit : Unit
{
    package Package[string] localeFilePkgMap;

    import gobject.Type : Type;
    import gobject.c.functions : g_object_get_data;
    import ascompose.c.functions: asc_unit_get_type;
    import ascompose.c.functions : asc_unit_get_user_data;

    struct AGLocaleUnit
    {
        AscUnit parentInstance;
    }

    struct AGLocaleUnitClass
    {
        AscUnitClass parentClass;
    }

    protected AGLocaleUnit *agLocaleUnit;

    protected override void* getStruct()
    {
        return cast(void*)gObject;
    }

    public synchronized static GType getType()
    {
        import std.algorithm : startsWith;

        GType agLocaleUnitType = Type.fromName("AGLocaleUnit");

        if (agLocaleUnitType == GType.INVALID) {
            agLocaleUnitType = Type.registerStaticSimple(
                                    asc_unit_get_type(),
                                    "AGLocaleUnit",
                                    cast(uint)AGLocaleUnitClass.sizeof,
                                    cast(GClassInitFunc) &agLocaleUnitClassInit,
                                    cast(uint)AGLocaleUnit.sizeof, null, cast(GTypeFlags)0);

            foreach (member; __traits(derivedMembers, LocaleUnit))
            {
                    static if (member.startsWith("_implementInterface"))
                            __traits(getMember, LocaleUnit, member)(agLocaleUnitType);
            }
        }

        return agLocaleUnitType;
    }

    public this (ContentsStore cstore, Package[] pkgList)
    {
        import std.array : array;
        import std.typecons : scoped;
        import std.string : toStringz;
        import glib.c.functions : g_strdup, g_free;
        import gobject.c.functions : g_object_newv;

        super (cast(AscUnit*) g_object_newv (getType (), 0, null), true);

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
    }

    extern(C)
    {
        static void agLocaleUnitClassInit (void* klass)
        {
            AscUnitClass *ascUnitClass = cast(AscUnitClass*) klass;
            gobject.c.types.GObjectClass *gobjectCTypesGObjectClass = cast(gobject.c.types.GObjectClass*)klass;

            ascUnitClass.open = &agLocaleUnitOpen;
            ascUnitClass.close = &agLocaleUnitClose;
            ascUnitClass.fileExists = &agLocaleUnitFileExists;
            ascUnitClass.dirExists = &agLocaleUnitDirExists;
            ascUnitClass.readData = &agLocaleUnitReadData;
        }

        static int agLocaleUnitOpen (AscUnit *iface, GError** err)
        {
            auto impl = cast(LocaleUnit) g_object_get_data (cast(GObject*)iface, "GObject".ptr);
            if (impl is null)
                impl = cast(LocaleUnit) asc_unit_get_user_data (iface);
            return impl.open ()? 1 : 0;
        }

        static void agLocaleUnitClose (AscUnit* iface)
        {
            auto impl = cast(LocaleUnit) g_object_get_data (cast(GObject*)iface, "GObject".ptr);
            if (impl is null)
                impl = cast(LocaleUnit) asc_unit_get_user_data (iface);
            impl.close();
        }

        static int agLocaleUnitFileExists (AscUnit* iface, const(char)* dirname)
        {
            import std.string : fromStringz;
            auto impl = cast(LocaleUnit) g_object_get_data (cast(GObject*)iface, "GObject".ptr);
            if (impl is null)
                impl = cast(LocaleUnit) asc_unit_get_user_data (iface);
            return impl.fileExists (dirname.fromStringz.to!string)? 1 : 0;
        }

        static int agLocaleUnitDirExists (AscUnit* iface, const(char)* dirname)
        {
            import std.string : fromStringz;
            auto impl = cast(LocaleUnit) g_object_get_data (cast(GObject*)iface, "GObject".ptr);
            if (impl is null)
                impl = cast(LocaleUnit) asc_unit_get_user_data (iface);
            return impl.dirExists (dirname.fromStringz.to!string)? 1 : 0;
        }

        static GBytes *agLocaleUnitReadData (AscUnit* iface, const(char)* filename, GError** err)
        {
            auto impl = cast(LocaleUnit) g_object_get_data (cast(GObject*)iface, "GObject".ptr);
            if (impl is null)
                impl = cast(LocaleUnit) asc_unit_get_user_data (iface);
            return impl.c_readData (filename, err);
        }
    }

    public override bool open ()
    {
        // we already opened everything in the constructor
        // (this enables us to reuse this fake unit multiple times)
        return true;
    }

    public override void close ()
    {
        //  noop
    }

	public override bool fileExists (string filename)
	{
	    return ((filename in localeFilePkgMap) is null)? false : true;
	}

	public override bool dirExists (string dirname)
	{
	    // not implemented yet, as it's not needed for locale finding (yet?)
		return false;
    }

	package GBytes *c_readData (const(char)* filename, GError** err)
	{
	    import glib.c.functions : g_bytes_new_take, g_memdup, g_set_error_literal;
	    import ascompose.c.types : ComposeError;
	    import ascompose.c.functions : asc_unit_get_user_data;
	    import std.string : toStringz, fromStringz;

	    const fname = filename.fromStringz.to!string;

	    auto pkgP = fname in localeFilePkgMap;
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
