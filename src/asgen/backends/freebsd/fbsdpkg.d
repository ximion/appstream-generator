/*
 * Copyright (C) 2023 Serenity Cyber Security, LLC
 * Author: Gleb Popov <arrowd@FreeBSD.org>
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

module asgen.backends.freebsd.fbsdpkg;

import std.stdio;
import std.json;
import std.path;
import std.string;
import std.array : empty;
import asgen.backends.interfaces;
import asgen.logging;
import asgen.zarchive;


final class FreeBSDPackage : Package
{
private:
    JSONValue pkgjson;

    string pkgFname;
    PackageKind _kind;

public:
    this (string pkgRoot, JSONValue[string] j)
    {
        pkgjson = j;
        pkgFname = buildPath (pkgRoot, pkgjson["repopath"].str());
        _kind = PackageKind.PHYSICAL;
    }

    @property override string name () const { return pkgjson["name"].str(); }
    @property override string ver () const { return pkgjson["version"].str(); }
    @property override string arch () const { return pkgjson["arch"].str(); }
    @property override string maintainer () const { return pkgjson["maintainer"].str(); }
    @property override string getFilename () const { return pkgFname; }


    @property override const(string[string]) summary () const
    {
        string[string] sums;
        sums["en"] = pkgjson["comment"].str();
        return sums;
    }

    @property override const(string[string]) description () const
    {
        string[string] descs;
        descs["en"] = pkgjson["desc"].str();
        return descs;
    }

    override
    const(ubyte[]) getFileData (string fname)
    {
        ArchiveDecompressor ad;
        ad.open (pkgFname);

        return ad.readData(fname);
    }

    @property override
    string[] contents ()
    {
        ArchiveDecompressor ad;
        ad.open (pkgFname);

        auto c = ad.readContents();

        //throw new Exception(join(c, "\n"));

        return c;
    }

    override
    void finish ()
    {
    }

    @property override
    PackageKind kind () @safe pure
    {
        return this._kind;
    }
}
