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
import std.file;
import std.array;
import asgen.backends.interfaces;
import asgen.logging;
import asgen.zarchive;


final class FreeBSDPackage : Package
{
private:
    JSONValue pkgJson;

    string pkgFname;
    PackageKind _kind;

    ArchiveDecompressor pkgArchive;
    string stageDir;
    bool isWorkdirPackage;

    string[] contentsL = null;

    this ()
    {
        _kind = PackageKind.PHYSICAL;
    }

public:
    this (string repoRoot, JSONValue[string] j)
    {
        pkgJson = j;
        pkgFname = buildPath (repoRoot, pkgJson["repopath"].str());
        _kind = PackageKind.PHYSICAL;
        isWorkdirPackage = false;
    }

    static FreeBSDPackage createFromWorkdir(string workDir)
    {
        auto ret = new FreeBSDPackage();
        ret.isWorkdirPackage = true;

        uint count = 0;
        foreach(f; dirEntries (buildPath (workDir, "pkg"), "*.pkg", SpanMode.shallow)) {
            ret.pkgFname = f;
            count++;
        }

        if (ret.pkgFname.empty) {
            logError ("Working dir '%s' does not contain any packages under in pkg/", workDir);
            return null;
        }

        if (count > 1) {
            logError ("Multiple packages found in pkg/, subpackages are not supported");
            return null;
        }

        ret.stageDir = buildPath (workDir, "stage");
        if (!isDir (ret.stageDir)) {
            logError ("Stage dir '%s' does not exist", ret.stageDir);
            return null;
        }

        ArchiveDecompressor ad;
        ad.open (ret.pkgFname);

        auto dataJson = parseJSON(assumeUTF(ad.readData("+COMPACT_MANIFEST")));
        if (dataJson.type != JSONType.object) {
            logError ("Fail to parse JSON from +COMPACT_MANIFEST of %s", ret.pkgFname);
            return null;
        }

        ret.pkgJson = dataJson.object;

        return ret;
    }

    @property override string name () const { return pkgJson["name"].str(); }
    @property override string ver () const { return pkgJson["version"].str(); }
    @property override string arch () const { return pkgJson["arch"].str(); }
    @property override string maintainer () const { return pkgJson["maintainer"].str(); }
    @property override string getFilename () const { return pkgFname; }


    @property override const(string[string]) summary () const
    {
        string[string] sums;
        sums["en"] = pkgJson["comment"].str();
        return sums;
    }

    @property override const(string[string]) description () const
    {
        string[string] descs;
        descs["en"] = pkgJson["desc"].str();
        return descs;
    }

    override
    const(ubyte[]) getFileData (string fname)
    {
        if (isWorkdirPackage)
            return cast(ubyte[])(read(stageDir ~ fname));

        if (!pkgArchive.isOpen)
            pkgArchive.open (this.getFilename);

        return pkgArchive.readData(fname);
    }

    @property override
    string[] contents ()
    {
        if (!this.contentsL.empty)
            return this.contentsL;

        if (isWorkdirPackage) {
            auto contents = appender!(string[]);
            foreach(f; dirEntries (stageDir, "*.*", SpanMode.depth)) {
                string p = asRelativePath (f, stageDir).array;
                if (p[0] != '/')
                    p = '/' ~ p;
                contents ~= p;
            }

            this.contentsL = contents.data;
            return this.contentsL;
        }

        if (!pkgArchive.isOpen)
            pkgArchive.open (this.getFilename);

        this.contentsL = pkgArchive.readContents ();
        return this.contentsL;
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
