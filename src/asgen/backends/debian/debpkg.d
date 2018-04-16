/*
 * Copyright (C) 2016-2017 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.backends.debian.debpkg;

import std.stdio;
import std.string;
import std.path;
import std.array : empty, appender;
import std.file : rmdirRecurse, mkdirRecurse;
import std.typecons : Nullable;
static import std.file;

import asgen.config;
import asgen.zarchive;
import asgen.backends.interfaces;
import asgen.logging;
import asgen.utils : isRemote, downloadFile;


/**
 * Helper class for simple deduplication of package descriptions
 * between packages of different architectures in memory.
 */
final class DebPackageLocaleTexts
{
    string[string] summary;     /// map of localized package short summaries
    string[string] description; /// map of localized package descriptions

    void setDescription (string text, string locale)
    {
        synchronized (this)
            description[locale] = text;
    }

    void setSummary (string text, string locale)
    {
        synchronized (this)
            summary[locale] = text;
    }
}


/**
 * Representation of a Debian binary package
 */
class DebPackage : Package
{
private:
    string pkgname;
    string pkgver;
    string pkgarch;
    string pkgmaintainer;
    DebPackageLocaleTexts descTexts;
    Nullable!GStreamer gstreamer;

    bool contentsRead;
    string[] contentsL;

    string tmpDir;
    ArchiveDecompressor controlArchive;
    ArchiveDecompressor dataArchive;

    string debFname;

public:
    final @property override string name () const { return pkgname; }
    final @property override string ver () const { return pkgver; }
    final @property override string arch () const { return pkgarch; }

    final @property void name (string s) { pkgname = s; }
    final @property void ver (string s) { pkgver = s; }
    final @property void arch (string s) { pkgarch = s; }

    final @property override Nullable!GStreamer gst () { return gstreamer; }
    final @property void gst (GStreamer gst) { gstreamer = gst; }

    final @property override const(string[string]) description () const { return descTexts.description; }
    final @property override const(string[string]) summary () const { return descTexts.summary; }

    override final
    @property string filename () const {
        if (debFname.isRemote) {
            immutable path = buildNormalizedPath (tmpDir, debFname.baseName);
            synchronized (this) {
                downloadFile (debFname, path);
            }
            return path;
        }
        return debFname;
    }
    final @property void   filename (string fname) { debFname = fname; }

    override
    final @property string maintainer () const { return pkgmaintainer; }
    final @property void   maintainer (string maint) { pkgmaintainer = maint; }

    this (string pname, string pver, string parch, DebPackageLocaleTexts l10nTexts = null)
    {
        pkgname = pname;
        pkgver = pver;
        pkgarch = parch;

        descTexts = l10nTexts;
        if (descTexts is null)
            descTexts = new DebPackageLocaleTexts;

        contentsRead = false;

        updateTmpDirPath ();
    }

    ~this ()
    {
        // FIXME: We can't properly clean up because we can't GC-allocate in a destructor (leads to crashes),
        // see if this is fixed in a future version of D, or simply don't use the GC in close ().
        // close ();
    }

    final void updateTmpDirPath ()
    {
        auto conf = Config.get ();
        tmpDir = buildPath (conf.getTmpDir (), format ("%s-%s_%s", name, ver, arch));
    }

    final void setDescription (string text, string locale)
    {
        descTexts.setDescription (text, locale);
    }

    final void setSummary (string text, string locale)
    {
        descTexts.setSummary (text, locale);
    }

    final setLocalizedTexts (DebPackageLocaleTexts l10nTexts)
    {
        assert (l10nTexts !is null);
        descTexts = l10nTexts;
    }

    @property
    final DebPackageLocaleTexts localizedTexts ()
    {
        return descTexts;
    }

    private auto openPayloadArchive ()
    {
        import std.regex : ctRegex;

        if (dataArchive.isOpen)
            return dataArchive;

        ArchiveDecompressor ad;
        // extract the payload to a temporary location first
        ad.open (this.filename);
        mkdirRecurse (tmpDir);

        auto files = ad.extractFilesByRegex (ctRegex!(r"data\.*"), tmpDir);
        if (files.length == 0)
            throw new Exception ("Unable to find the payload tarball in Debian package: %s".format (this.filename));
        immutable dataArchiveFname = files[0];

        dataArchive.open (dataArchiveFname);
        return dataArchive;
    }

    protected final void extractPackage (const string dest = buildPath (tmpDir, name))
    {
        import std.file : exists;
        import std.regex : ctRegex;

        if (!dest.exists)
            mkdirRecurse (dest);

        auto pa = openPayloadArchive ();
        pa.extractArchive (dest);
    }

    private final auto openControlArchive ()
    {
        import std.regex;

        if (controlArchive.isOpen)
            return controlArchive;

        ArchiveDecompressor ad;
        // extract the payload to a temporary location first
        ad.open (this.filename);
        mkdirRecurse (tmpDir);

        auto files = ad.extractFilesByRegex (ctRegex!(r"control\.*"), tmpDir);
        if (files.empty)
            throw new Exception ("Unable to find control data in Debian package: %s".format (this.filename));
        immutable controlArchiveFname = files[0];

        controlArchive.open (controlArchiveFname);
        return controlArchive;
    }

    override final
    const(ubyte)[] getFileData (string fname)
    {
        auto pa = openPayloadArchive ();
        return pa.readData (fname);
    }

    @property override final
    string[] contents ()
    {
        import std.utf;

        if (contentsRead)
            return contentsL;

        if (pkgname.endsWith ("icon-theme")) {
            // the md5sums file does not contain symbolic links - while that is okay-ish for regular
            // packages, it is not acceptable for icon themes, since those rely on symlinks to provide
            // aliases for certain icons. So, use the slow method for reading contents information here.

            auto pa = openPayloadArchive ();
            contentsL = pa.readContents ();
            contentsRead = true;

            return contentsL;
        }

        // use the md5sums file of the .deb control archive to determine
        // the contents of this package.
        // this is way faster than going through the payload directly, and
        // has the same accuracy.
        auto ca = openControlArchive ();
        const(ubyte)[] md5sumsData;
        try {
            md5sumsData = ca.readData ("./md5sums");
        } catch (Exception e) {
            logWarning ("Could not read md5sums file for package %s: %s", this.id, e.msg);
            return [];
        }

        auto md5sums = cast(string) md5sumsData;
        try {
            md5sums = md5sums.toUTF8;
        } catch (Exception e) {
            logError ("Could not decode md5sums file for package %s: %s", this.id, e.msg);
            return [];
        }

        auto contentsAppender = appender!(string[]);
        contentsAppender.reserve (20);
        foreach (line; md5sums.splitLines ()) {
            auto parts = line.split ("  ");
            if (parts.length <= 0)
                continue;
            string c = join (parts[1..$], "  ");
            contentsAppender.put ("/" ~ c);
        }
        contentsL = contentsAppender.data;

        contentsRead = true;
        return contentsL;
    }

    /**
     * Get the "control" file information from the control archive
     * in the Debian package.
     * This is useful to get information from a package directly, e.g.
     * for processing a single package.
     */
    final auto readControlInformation ()
    {
        import std.utf : toUTF8;
        import asgen.backends.debian.tagfile : TagFile;

        auto ca = openControlArchive ();
        const(ubyte)[] controlData;
        try {
            controlData = ca.readData ("./control");
        } catch (Exception e) {
            logError ("Could not read control file for package %s: %s", this.id, e.msg);
            return null;
        }

        auto controlStr = cast(string) controlData;
        try {
            controlStr = controlStr.toUTF8;
        } catch (Exception e) {
            logError ("Could not decode control file for package %s: %s", this.id, e.msg);
            return null;
        }

        auto tf = new TagFile ();
        tf.load (controlStr);
        return tf;
    }

    override final
    void close ()
    {
        controlArchive.close ();
        dataArchive.close ();

        try {
            if (std.file.exists (tmpDir))
                rmdirRecurse (tmpDir);
        } catch (Throwable) {
            // we ignore any error
        }
    }
}
