/*
 * Copyright (C) 2018-2022 Matthias Klumpp <matthias@tenstral.net>
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

import glib.PtrArray : PtrArray;
import glib.c.types : GQuark, GError, GBytes;

import appstream.c.types : BundleKind;
import ascompose.Unit : Unit;
import ascompose.c.types;

import asgen.backends.interfaces : Package;

private __gshared extern (C) GQuark asc_compose_error_quark ();

/**
 * Unit implementation that wraps a package.
 */
public final class PackageUnit : Unit {
    package Package pkg;

    import gobject.Type : Type;
    import gobject.c.functions : g_object_get_data;
    import ascompose.c.functions : asc_unit_get_type;
    import ascompose.c.functions : asc_unit_get_user_data;

    struct AGPackageUnit {
        AscUnit parentInstance;
    }

    struct AGPackageUnitClass {
        AscUnitClass parentClass;
    }

    protected AGPackageUnit* agPackageUnit;

    protected override void* getStruct()
    {
        return cast(void*) gObject;
    }

    public synchronized static GType getType ()
    {
        import std.algorithm : startsWith;

        GType agPackageUnitType = Type.fromName("AGPackageUnit");
        if (agPackageUnitType == GType.INVALID) {
            agPackageUnitType = Type.registerStaticSimple(
                    asc_unit_get_type(),
                    "AGPackageUnit",
                    cast(uint) AGPackageUnitClass.sizeof,
                    cast(GClassInitFunc)&agPackageUnitClassInit,
                    cast(uint) AGPackageUnit.sizeof, null, cast(GTypeFlags) 0);

            foreach (member; __traits(derivedMembers, PackageUnit)) {
                static if (member.startsWith("_implementInterface"))
                    __traits(getMember, PackageUnit, member)(agPackageUnitType);
            }
        }

        return agPackageUnitType;
    }

    public this (Package pack)
    {
        import std.array : array;
        import std.typecons : scoped;
        import std.string : toStringz;
        import glib.c.functions : g_strdup, g_free;
        import gobject.c.functions : g_object_newv;

        super(cast(AscUnit*) g_object_newv (getType(), 0, null), true);

        this.pkg = pack;

        // helper for function override callbacks
        setUserData(cast(void*) this);

        // set identity
        setBundleId(pkg.name);
        setBundleKind(BundleKind.PACKAGE);

        auto contents = new PtrArray(pkg.contents.length.to!uint,
                &g_free);
        foreach (const ref fname; pkg.contents)
            contents.add(cast(void*) g_strdup (fname.toStringz));
        setContents(contents);
    }

    extern (C) {
        static void agPackageUnitClassInit (void* klass)
        {
            AscUnitClass* ascUnitClass = cast(AscUnitClass*) klass;
            gobject.c.types.GObjectClass* gobjectCTypesGObjectClass = cast(gobject.c.types.GObjectClass*) klass;

            ascUnitClass.open = &agPackageUnitOpen;
            ascUnitClass.close = &agPackageUnitClose;
            ascUnitClass.dirExists = &agPackageUnitDirExists;
            ascUnitClass.readData = &agPackageUnitReadData;
        }

        static int agPackageUnitOpen (AscUnit* iface, GError** err)
        {
            auto impl = cast(PackageUnit) g_object_get_data (cast(GObject*) iface, "GObject".ptr);
            if (impl is null)
                impl = cast(PackageUnit) asc_unit_get_user_data (iface);
            return impl.open() ? 1 : 0;
        }

        static void agPackageUnitClose (AscUnit* iface)
        {
            auto impl = cast(PackageUnit) g_object_get_data (cast(GObject*) iface, "GObject".ptr);
            if (impl is null)
                impl = cast(PackageUnit) asc_unit_get_user_data (iface);
            impl.close();
        }

        static int agPackageUnitDirExists (AscUnit* iface, const(char)* dirname)
        {
            import std.string : fromStringz;

            auto impl = cast(PackageUnit) g_object_get_data (cast(GObject*) iface, "GObject".ptr);
            if (impl is null)
                impl = cast(PackageUnit) asc_unit_get_user_data (iface);
            return impl.dirExists(dirname.fromStringz.to!string) ? 1 : 0;
        }

        static GBytes* agPackageUnitReadData(AscUnit* iface, const(char)* filename, GError** err)
        {
            auto impl = cast(PackageUnit) g_object_get_data (cast(GObject*) iface, "GObject".ptr);
            if (impl is null)
                impl = cast(PackageUnit) asc_unit_get_user_data (iface);
            return impl.c_readData(filename, err);
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
        pkg.finish();
    }

    public override bool dirExists (string dirname)
    {
        // not implemented yet, as it's not needed (yet?)
        return false;
    }

    package GBytes* c_readData(const(char)* filename, GError** err)
    {
        import glib.c.functions : g_bytes_new_take, g_memdup, g_set_error_literal;
        import ascompose.c.types : ComposeError;
        import std.string : toStringz, fromStringz;

        const data = pkg.getFileData(filename.fromStringz.to!string);

        // FIXME: We should use g_memdup2 here, once we can bump the GLib version!
        void* ncCopy = g_memdup(cast(void*) data.ptr, cast(uint) data.length);
        return g_bytes_new_take(ncCopy, cast(size_t) data.length);
    }
}
