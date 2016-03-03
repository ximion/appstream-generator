/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This library is free software: you can redistribute it and/or modify
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
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 */

module ag.backend.debian.debpackage;

import std.stdio;
import std.string;
import std.process;
import std.file;
import ag.utils;
import ag.archive;
import ag.backend.intf;


class DebPackage : Package
{
private:
    string pkgname;
    string pkgver;
    string pkgarch;

    bool contentsRead;
    string[] contents;

    string tmpDir;
    string dataArchive;

public:
    string filename;

    @property string name () { return pkgname; }
    @property string ver () { return pkgver; }
    @property string arch () { return pkgarch; }
    @property string[string] description () { return null; }

    this (string pname, string pver, string parch)
    {
        import std.path;

        pkgname = pname;
        pkgver = pver;
        pkgarch = parch;

        contentsRead = false;
        tmpDir = buildPath (getAgTmpDir (), format ("%s-%s_%s", name, ver, arch));
    }

    ~this ()
    {
        // FIXME: Makes the GC crash - find out why (the error should be ignored...)
        // close ();
    }

    bool isValid ()
    {
        if ((!name) || (!ver) || (!arch))
            return false;
        return true;
    }

    string getFileData (string fname)
    {
        auto ca = new CompressedArchive ();
        if (!dataArchive) {
            import std.regex;
            import std.path;

            // extract the payload to a temporary location first
            ca.open (this.filename);
            mkdirRecurse (tmpDir);

            string[] files;
            try {
                files = ca.extractFilesByRegex (ctRegex!(r"data\.*"), tmpDir);
            } catch (Exception e) { throw e; }

            if (files.length == 0)
                return null;
            dataArchive = files[0];
        }

        ca.open (dataArchive);

        string data;
        try {
            data = ca.readData (fname);
        } catch (Exception e) { throw e; }

        return data;
    }

    string[] getContentsList ()
    {
        if (contentsRead)
            return contents;

        auto pipes = pipeProcess (["dpkg", "--contents", filename], Redirect.stdout | Redirect.stderr);
        auto ret = wait (pipes.pid);
        if (ret != 0) {
            writeln ("ERROR: Unable to read data from '%s'", filename);
            return contents;
        }

        // Store lines of output.
        string[] output;
        foreach (line; pipes.stdout.byLine) {
            auto idx = indexOf (line.idup, "./");
            if (idx <= 0)
                continue;
            string fname = line.idup[idx+1..$];

            auto link_idx = indexOf (fname, " -> ");
            if (link_idx > 0)
                fname = strip (fname[0..link_idx]);

            // add it to the index if it isn't a directory
            if (!endsWith(fname, "/"))
                contents ~= fname;
        }

        contentsRead = true;
        return contents;
    }

    void close ()
    {
        try {
            if (exists (tmpDir))
                rmdirRecurse (tmpDir);
        } catch {}
    }
}
