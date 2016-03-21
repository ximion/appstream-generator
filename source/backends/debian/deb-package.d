/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
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

module ag.backend.debian.debpackage;

import std.stdio;
import std.string;
import std.process : pipeProcess, Redirect, wait;
import std.file;
import std.array : empty;
import ag.config;
import ag.archive;
import ag.backend.intf;


class DebPackage : Package
{
private:
    string pkgname;
    string pkgver;
    string pkgarch;

    bool contentsRead;
    string[] contentsL;

    string tmpDir;
    string dataArchive;
    string controlArchive;

    string debFname;

public:
    @property string name () { return pkgname; }
    @property string ver () { return pkgver; }
    @property string arch () { return pkgarch; }
    @property string[string] description () { return null; }
    @property string filename () { return debFname; }
    @property void filename (string fname) { debFname = fname; }

    this (string pname, string pver, string parch)
    {
        import std.path;

        pkgname = pname;
        pkgver = pver;
        pkgarch = parch;

        contentsRead = false;

        auto conf = Config.get ();
        tmpDir = buildPath (conf.getTmpDir (), format ("%s-%s_%s", name, ver, arch));
    }

    ~this ()
    {
        // FIXME: Makes the GC crash - find out why (the error should be ignored...)
        // if (tmpDir !is null)
        // close ();
    }

    bool isValid ()
    {
        if ((!name) || (!ver) || (!arch))
            return false;
        return true;
    }

    override
    string toString ()
    {
        return format ("%s/%s/%s", name, ver, arch);
    }

    private CompressedArchive openPayloadArchive ()
    {
        auto pa = new CompressedArchive ();
        if (!dataArchive) {
            import std.regex;
            import std.path;

            // extract the payload to a temporary location first
            pa.open (this.filename);
            mkdirRecurse (tmpDir);

            string[] files;
            try {
                files = pa.extractFilesByRegex (ctRegex!(r"data\.*"), tmpDir);
            } catch (Exception e) { throw e; }

            if (files.length == 0)
                return null;
            dataArchive = files[0];
        }

        pa.open (dataArchive);
        return pa;
    }

    private CompressedArchive openControlArchive ()
    {
        auto ca = new CompressedArchive ();
        if (!controlArchive) {
            import std.regex;
            import std.path;

            // extract the payload to a temporary location first
            ca.open (this.filename);
            mkdirRecurse (tmpDir);

            string[] files;
            try {
                files = ca.extractFilesByRegex (ctRegex!(r"control\.*"), tmpDir);
            } catch (Exception e) { throw e; }

            if (files.empty)
                return null;
            controlArchive = files[0];
        }

        ca.open (controlArchive);
        return ca;
    }

    string getFileData (string fname)
    {
        auto pa = openPayloadArchive ();
        string data;
        try {
            data = pa.readData (fname);
        } catch (Exception e) { throw e; }

        return data;
    }

    @property
    string[] contents ()
    {
        if (contentsRead)
            return contentsL;

        // use the md5sums file of the .deb control archive to determine
        // the contents of this package.
        // this is way faster than going through the payload directly, and
        // has the same accuracy.
        auto ca = openControlArchive ();
        auto md5sums = ca.readData ("./md5sums");

        // TODO: Preallocate space for the contents list using
        // the splitLines count?

        foreach (line; md5sums.splitLines ()) {
            auto parts = line.split ("  ");
            if (parts.length <= 0)
                continue;
            string c = join (parts[1..$], "  ");
            contentsL ~= "/" ~ c;
        }

        contentsRead = true;
        return contentsL;
    }

    void close ()
    {
        try {
            if (exists (tmpDir))
                rmdirRecurse (tmpDir);
        } catch {}
    }
}
