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

import std.stdio : File;
import std.array : empty;
import std.path : buildPath, buildNormalizedPath, relativePath, baseName;

import asgen.backends.interfaces;
import asgen.utils : GENERIC_BUFFER_SIZE, existsAndIsDir;
import asgen.logging;

/**
 * Fake package which has the sole purpose of allowing easy injection of local
 * data that does not reside in packages.
 */
final class DataInjectPackage : Package {
private:
    string pkgname;
    string pkgarch;
    string pkgmaintainer;
    string[string] desc;
    string[string] _contents;
    string _dataLocation;
    string _archDataLocation;

public:
    @property override string name () const
    {
        return pkgname;
    }

    @property override string ver () const
    {
        return "0~0";
    }

    @property override string arch () const
    {
        return pkgarch;
    }

    @property override PackageKind kind () @safe pure
    {
        return PackageKind.FAKE;
    }

    @property override const(string[string]) description () const
    {
        return desc;
    }

    override
    @property string getFilename () const
    {
        return "_local_";
    }

    override
    @property string maintainer () const
    {
        return pkgmaintainer;
    }

    @property void maintainer (string maint)
    {
        pkgmaintainer = maint;
    }

    @property string dataLocation () const
    {
        return _dataLocation;
    }

    @property void dataLocation (string value)
    {
        _dataLocation = value;
    }

    @property string archDataLocation () const
    {
        return _archDataLocation;
    }

    @property void archDataLocation (string value)
    {
        _archDataLocation = value;
    }

    this (string pname, string parch)
    {
        pkgname = pname;
        pkgarch = parch;
    }

    override
    ubyte[] getFileData (string fname)
    {
        immutable localPath = _contents.get(fname, null);
        if (localPath.empty)
            return [];

        ubyte[] data;
        auto f = File(localPath, "r");
        while (!f.eof) {
            char[GENERIC_BUFFER_SIZE] buf;
            data ~= f.rawRead(buf);
        }

        return data;
    }

    @property override
    string[] contents ()
    {
        import std.file : dirEntries, SpanMode;
        import std.array : array;

        if (!_contents.empty)
            return array(_contents.byKey);

        if (_dataLocation.empty || !_dataLocation.existsAndIsDir)
            return [];

        // find all icons
        immutable iconLocation = buildNormalizedPath(_dataLocation, "icons");
        if (iconLocation.existsAndIsDir) {
            foreach (iconFname; iconLocation.dirEntries("*.{svg,svgz,png}", SpanMode.breadth, true)) {
                immutable iconBasePath = relativePath(iconFname, iconLocation);
                _contents[buildPath("/usr/share/icons/hicolor", iconBasePath)] = iconFname;
            }
        } else {
            logInfo("No icons found in '%s' for injected metadata.", iconLocation);
        }

        // find metainfo files
        foreach (miFname; _dataLocation.dirEntries("*.xml", SpanMode.shallow, false)) {
            immutable miBasename = miFname.baseName;
            logDebug("Found injected metainfo [%s]: %s", "all", miBasename);
            _contents[buildPath("/usr/share/metainfo", miBasename)] = miFname;
        }

        if (!archDataLocation.existsAndIsDir)
            return array(_contents.byKey);

        // load arch-specific override metainfo files
        foreach (miFname; archDataLocation.dirEntries("*.xml", SpanMode.shallow, false)) {
            immutable miBasename = miFname.baseName;
            immutable fakePath = buildPath("/usr/share/metainfo", miBasename);

            if (fakePath in _contents)
                logDebug ("Found injected metainfo [%s]: %s (replacing generic one)", arch, miBasename);
            else
                logDebug("Found injected metainfo [%s]: %s", arch, miBasename);

            _contents[fakePath] = miFname;
        }

        return array(_contents.byKey);
    }

    override
    void finish ()
    {
    }
}
