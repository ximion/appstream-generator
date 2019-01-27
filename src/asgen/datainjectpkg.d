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

import std.stdio : File;
import std.array : empty;
import std.path : buildPath, relativePath;
import containers : HashMap;

import asgen.backends.interfaces;
import asgen.utils : GENERIC_BUFFER_SIZE;
import asgen.logging;


/**
 * Fake package which has the sole purpose of allowing easy injection of local
 * data that does not reside in packages.
 */
final class DataInjectPackage : Package
{
private:
    string pkgname;
    string pkgarch;
    string pkgmaintainer;
    string[string] desc;
    HashMap!(string, string) _contents;
    string _dataLocation;

public:
    @property override string name () const { return pkgname; }
    @property override string ver () const { return "0~0"; }
    @property override string arch () const { return pkgarch; }
    @property override PackageKind kind () @safe pure { return PackageKind.FAKE; }

    @property override const(string[string]) description () const { return desc; }

    override
    @property string getFilename () const { return "_local_"; }

    override
    @property string maintainer () const { return pkgmaintainer; }
    @property void   maintainer (string maint) { pkgmaintainer = maint; }

    @property string dataLocation () const { return _dataLocation; }
    @property void   dataLocation (string value) { _dataLocation = value; }

    this (string pname, string parch)
    {
        pkgname = pname;
        pkgarch = parch;
    }

    override
    ubyte[] getFileData (string fname)
    {
        immutable localPath = _contents.get (fname, null);
        if (localPath.empty)
            return [];

        ubyte[] data;
        auto f = File (localPath, "r");
        while (!f.eof) {
            char[GENERIC_BUFFER_SIZE] buf;
            data ~= f.rawRead (buf);
        }

        return data;
    }

    @property override
    string[] contents ()
    {
        import std.file : dirEntries, SpanMode;

        if (_dataLocation.empty)
            return [];

        if (!_contents.empty)
            return _contents.keys;

        foreach (iconFname; _dataLocation.dirEntries ("*.{svg,svgz,png}", SpanMode.breadth, true)) {
            immutable iconBasePath = relativePath (iconFname, _dataLocation);
            _contents[buildPath ("/usr/share/icons/hicolor", iconBasePath)] = iconFname;
        }

        return _contents.keys;
    }

    override
    void close ()
    {
    }
}
