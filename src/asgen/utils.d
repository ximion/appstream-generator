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

module asgen.utils;
@safe:

import std.stdio : File, write, writeln;
import std.string;
import std.ascii : letters, digits;
import std.conv : to;
import std.random : randomSample;
import std.range : chain;
import std.algorithm : startsWith;
import std.array : appender, empty;
import std.path : buildPath, dirName, buildNormalizedPath;
import std.typecons : Nullable;
import std.datetime : Clock, parseRFC822DateTime, SysTime;
static import std.file;

import appstream.Component;
import appstream.Icon;

import asgen.logging;
import asgen.defines;

public immutable DESKTOP_GROUP = "Desktop Entry";

public immutable GENERIC_BUFFER_SIZE = 2048;

struct ImageSize
{
    uint width;
    uint height;

    this (uint w, uint h)
    {
        width = w;
        height = h;
    }

    this (uint s)
    {
        width = s;
        height = s;
    }

    string toString () const
    {
        return format ("%sx%s", width, height);
    }

    uint toInt () const
    {
        if (width > height)
            return width;
        return height;
    }

    int opCmp (const ImageSize s) const
    {
        // only compares width, should be enough for now
        if (this.width > s.width)
            return 1;
        if (this.width == s.width)
            return 0;
        return -1;
    }
}

/**
 * Generate a random alphanumeric string.
 */
@trusted
string randomString (uint len)
{
    auto asciiLetters = to! (dchar[]) (letters);
    auto asciiDigits = to! (dchar[]) (digits);

    if (len == 0)
        len = 1;

    auto res = to!string (randomSample (chain (asciiLetters, asciiDigits), len));
    return res;
}

/**
 * Check if the locale is a valid locale which we want to include
 * in the resulting metadata. Some locales added just for testing
 * by upstreams should be filtered out.
 */
@safe
bool localeValid (string locale) pure
{
    switch (locale) {
        case "x-test":
        case "xx":
            return false;
        default:
            return true;
    }
}

/**
 * Check if the given string is a top-level domain name.
 * The TLD list of AppStream is incomplete, but it will
 * cover 99% of all cases.
 * (in a short check on Debian, it covered all TLDs in use there)
 */
@trusted
bool isTopLevelDomain (const string value) pure
{
    import asgen.bindings.appstream_utils;
    if (value.empty)
        return false;
    return as_utils_is_tld (value.toStringz);
}

/**
 * Build a global component ID.
 *
 * The global-id is used as a global, unique identifier for this component.
 * (while the component-ID is local, e.g. for one suite).
 * Its primary usecase is to identify a media directory on the filesystem which is
 * associated with this component.
 **/
@trusted
string buildCptGlobalID (string cid, string checksum, bool allowNoChecksum = false) pure
in { assert (cid.length >= 2); }
body
{
    if (cid is null)
        return null;
    if ((!allowNoChecksum) && (checksum is null))
            return null;
    if (checksum is null)
        checksum = "";

    // check whether we can build the gcid by using the reverse domain name,
    // or whether we should use the simple standard splitter.
    auto reverseDomainSplit = false;
    immutable parts = cid.split (".");
    if (parts.length > 2) {
        // check if we have a valid TLD. If so, use the reverse-domain-name splitting.
        if (isTopLevelDomain (parts[0]))
            reverseDomainSplit = true;
    }

    string gcid;
    if (reverseDomainSplit)
        gcid = "%s/%s/%s/%s".format (parts[0].toLower(), parts[1], join (parts[2..$], "."), checksum);
    else
        gcid = "%s/%s/%s/%s".format (cid[0].toLower(), cid[0..2].toLower(), cid, checksum);

    return gcid;
}

/**
 * Get the component-id back from a global component-id.
 */
@trusted
string getCidFromGlobalID (string gcid) pure
{
    import asgen.bindings.appstream_utils;

    auto parts = gcid.split ("/");
    if (parts.length != 4)
        return null;
    if (isTopLevelDomain (parts[0])) {
        return join (parts[0..3], ".");
    }

    return parts[2];
}

@trusted
void hardlink (const string srcFname, const string destFname)
{
    import core.sys.posix.unistd;
    import core.stdc.string;
    import core.stdc.errno;

    immutable res = link (srcFname.toStringz, destFname.toStringz);
    if (res != 0)
        throw new std.file.FileException ("Unable to create link: %s".format (errno.strerror));
}

/**
 * Copy a directory using multiple threads.
 * This function follows symbolic links,
 * and replaces them with actual directories
 * in destDir.
 *
 * Params:
 *      srcDir = Source directory to copy.
 *      destDir = Path to the destination directory.
 *      useHardlinks = Use hardlinks instead of copying files.
 */
void copyDir (in string srcDir, in string destDir, bool useHardlinks = false) @trusted
{
    import std.file;
    import std.path;
    import std.parallelism;
    import std.array : appender;

    auto deSrc = DirEntry (srcDir);
    auto files = appender!(string[]);

    if (!exists (destDir)) {
        mkdirRecurse (destDir);
    }

 	auto deDest = DirEntry (destDir);
    if(!deDest.isDir ()) {
        throw new FileException (deDest.name, " is not a directory");
    }

    immutable destRoot = deDest.name ~ '/';

    if (!deSrc.isDir ()) {
        if (useHardlinks)
            hardlink (deSrc.name, destRoot);
        else
            std.file.copy (deSrc.name, destRoot);
    } else {
        auto srcLen = deSrc.name.length;
        if (!std.file.exists (destRoot))
            mkdir (destRoot);

        // make an array of the regular files and create the directory structure
        // Since it is SpanMode.breadth, we can just use mkdir
        foreach (DirEntry e; dirEntries (deSrc.name, SpanMode.breadth, true)) {
            if (attrIsDir (e.attributes)) {
                auto childDir = destRoot ~ e.name[srcLen..$];
                mkdir (childDir);
            } else {
                files ~= e.name;
            }
        }

        // parallel foreach for regular files
        foreach (fn; taskPool.parallel (files.data, 100)) {
            immutable destFn = destRoot ~ fn[srcLen..$];

            if (useHardlinks)
                hardlink (fn, destFn);
            else
                std.file.copy (fn, destFn);
        }
    }
}

/**
 * Escape XML characters.
 */
@safe
S escapeXml (S) (S s) pure
{
    string r;
    size_t lastI;
    auto result = appender!S ();

    foreach (i, c; s) {
        switch (c) {
            case '&':  r = "&amp;"; break;
            case '"':  r = "&quot;"; break;
            case '\'': r = "&apos;"; break;
            case '<':  r = "&lt;"; break;
            case '>':  r = "&gt;"; break;
            default: continue;
        }

        // Replace with r
        result.put (s[lastI .. i]);
        result.put (r);
        lastI = i + 1;
    }

    if (!result.data.ptr)
        return s;
    result.put (s[lastI .. $]);
    return result.data;
}

/**
 * Get full path for an AppStream generator data file.
 */
@safe
string getDataPath (string fname)
{
    import std.path;
    auto resPath = buildPath (DATADIR, fname);

    if (std.file.exists (resPath))
        return resPath;

    resPath = buildNormalizedPath (dirName(std.file.thisExePath ()), "..", "data", fname);
    if (std.file.exists (resPath))
        return resPath;

    /* Uh, let's just give up */
    return buildPath ("/usr", "share", "appstream", fname);
}

/**
 * Check if a path exists and is a directory.
 */
bool existsAndIsDir (string path) @safe
{
    if (std.file.exists (path))
        if (std.file.isDir (path))
            return true;
    return false;
}

/**
 * Convert a string array into a byte array.
 */
ubyte[] stringArrayToByteArray (string[] strArray) pure @trusted
{
    auto res = appender!(ubyte[]);
    res.reserve (strArray.length * 2); // make a guess, we will likely need much more space

    foreach (ref s; strArray) {
        res ~= cast(ubyte[]) s;
    }

    return res.data;
}

/**
 * Check if string contains a remote URI.
 */
@safe
bool isRemote (const string uri)
{
    import std.regex;

    auto uriregex = ctRegex!(`^(https?|ftps?)://`);
    auto match = matchFirst (uri, uriregex);

    return (!match.empty);
}

private immutable(Nullable!SysTime) download (const string url, ref File dest, const uint retryCount = 5) @trusted
in { assert (url.isRemote); }
body
{
    import core.time;
    import std.net.curl : CurlException, HTTP, FTP;

    Nullable!SysTime ret;

    size_t onReceiveCb (File f, ubyte[] data)
    {
        f.rawWrite (data);
        return data.length;
    }

    /* the curl library is stupid; you can't make an AutoProtocol to set timeouts */
    logDebug ("Downloading %s", url);
    try {
        if (url.startsWith ("http")) {
            auto downloader = HTTP (url);
            downloader.connectTimeout = dur!"seconds" (30);
            downloader.dataTimeout = dur!"seconds" (30);
            downloader.onReceive = (data) => onReceiveCb (dest, data);
            downloader.perform();
            if ("last-modified" in downloader.responseHeaders) {
                    auto lastmodified = downloader.responseHeaders["last-modified"];
                    ret = parseRFC822DateTime(lastmodified);
            }
        } else {
            auto downloader = FTP (url);
            downloader.connectTimeout = dur!"seconds" (30);
            downloader.dataTimeout = dur!"seconds" (30);
            downloader.onReceive = (data) => onReceiveCb (dest, data);
            downloader.perform();
        }
        logDebug ("Downloaded %s", url);
    } catch (CurlException e) {
        if (retryCount > 0) {
            logDebug ("Failed to download %s, will retry %d more %s",
                      url,
                      retryCount,
                      retryCount > 1 ? "times" : "time");
            download (url, dest, retryCount - 1);
        } else {
            throw e;
        }
    }

    return ret;
}

/**
 * Download or open `path` and return it as a string array.
 *
 * Params:
 *      path = The path to access.
 *
 * Returns: The data if successful.
 */
string[] getFileContents (const string path, const uint retryCount = 5) @trusted
{
    import core.stdc.stdlib : free;
    import core.sys.posix.stdio : fclose, open_memstream;

    char * ptr = null;
    scope (exit) free (ptr);

    size_t sz = 0;

    if (path.isRemote) {
        {
            auto f = open_memstream (&ptr, &sz);
            scope (exit) fclose (f);
            auto file = File.wrapFile (f);
            download (path, file, retryCount);
        }

        return to!string (ptr.fromStringz).splitLines;
    } else {
        if (!std.file.exists (path))
            throw new Exception ("No such file '%s'", path);

        return std.file.readText (path).splitLines;
    }
}

/**
 * Download `url` to `dest`.
 *
 * Params:
 *      url = The URL to download.
 *      dest = The location for the downloaded file.
 *      retryCount = Number of times to retry on timeout.
 */
void downloadFile (const string url, const string dest, const uint retryCount = 5) @trusted
in  { assert (url.isRemote); }
out { assert (std.file.exists (dest)); }
body
{
    import std.file;

    if (dest.exists) {
        logDebug ("Already downloaded '%s' into '%s', won't redownload", url, dest);
        return;
    }

    mkdirRecurse (dest.dirName);

    auto f = File (dest, "wb");
    scope (failure) remove (dest);

    auto time = download (url, f, retryCount);

    f.close ();
    if (!time.isNull)
        setTimes (dest, Clock.currTime, time);
}

/**
 * Get path of the directory with test samples.
 * The function will look for test data in the current
 * working directory.
 */
string
getTestSamplesDir () @trusted
{
    import std.path : getcwd;

    auto path = buildPath (getcwd (), "test", "samples");
    if (std.file.exists (path))
        return path;
    path = buildNormalizedPath (getcwd (), "..", "test", "samples");

    return path;
}

/**
 * Return stock icon for this component, or null if it does not
 * have one.
 */
@system
Nullable!Icon componentGetStockIcon (ref Component cpt)
{
    Nullable!Icon res;
    auto iconsArr = cpt.getIcons ();

    for (uint i = 0; i < iconsArr.len; i++) {
        // cast array data to D AsIcon and keep a reference to the C struct
        auto icon = new Icon (cast (AsIcon*) iconsArr.index (i));
        if (icon.getKind() == IconKind.STOCK) {
            res = icon;
            return res;
        }
    }

    return res;
}

unittest
{
    writeln ("TEST: ", "GCID");

    assert (buildCptGlobalID ("foobar.desktop", "DEADBEEF") == "f/fo/foobar.desktop/DEADBEEF");
    assert (buildCptGlobalID ("org.gnome.yelp.desktop", "DEADBEEF") == "org/gnome/yelp.desktop/DEADBEEF");
    assert (buildCptGlobalID ("noto-cjk.font", "DEADBEEF") == "n/no/noto-cjk.font/DEADBEEF");
    assert (buildCptGlobalID ("io.sample.awesomeapp.sdk", "ABAD1DEA") == "io/sample/awesomeapp.sdk/ABAD1DEA");

    assert (buildCptGlobalID ("io.sample.awesomeapp.sdk", null, true) == "io/sample/awesomeapp.sdk/");

    assert (getCidFromGlobalID ("f/fo/foobar.desktop/DEADBEEF") == "foobar.desktop");
    assert (getCidFromGlobalID ("org/gnome/yelp.desktop/DEADBEEF") == "org.gnome.yelp.desktop");

    assert (ImageSize (80, 40).toString () == "80x40");
    assert (ImageSize (1024, 420).toInt () == 1024);
    assert (ImageSize (1024, 800) > ImageSize (64, 32));
    assert (ImageSize (48) < ImageSize (64));

    assert (stringArrayToByteArray (["A", "b", "C", "ö", "8"]) == [65, 98, 67, 195, 182, 56]);

    assert (isRemote ("http://test.com"));
    assert (isRemote ("https://example.org"));
    assert (!isRemote ("/srv/mirror"));
    assert (!isRemote ("file:///srv/test"));
}
