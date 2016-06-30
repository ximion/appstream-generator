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

module ag.utils;

import std.stdio : writeln;
import std.string;
import std.ascii : letters, digits;
import std.conv : to;
import std.random : randomSample;
import std.range : chain;
import std.algorithm : startsWith;
import std.array : appender;


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
 * Build a global component ID.
 *
 * The global-id is used as a global, unique identifier for this component.
 * (while the component-ID is local, e.g. for one suite).
 * Its primary usecase is to identify a media directory on the filesystem which is
 * associated with this component.
 **/
@trusted
string buildCptGlobalID (string cptid, string checksum, bool allowNoChecksum = false) pure
{
    if (cptid is null)
        return null;
    if ((!allowNoChecksum) && (checksum is null))
            return null;
    if (checksum is null)
        checksum = "";

    string gid;
    string[] parts = null;
    if (startsWith (cptid, "org.", "net.", "com.", "io.", "edu.", "name.")) {
        parts = cptid.split (".");
    }

    if ((parts !is null) && (parts.length > 2))
        gid = format ("%s/%s/%s/%s", parts[0].toLower(), parts[1], join (parts[2..$], "."), checksum);
    else
        gid = format ("%s/%s/%s/%s", cptid[0].toLower(), cptid[0..2].toLower(), cptid, checksum);

    return gid;
}

/**
 * Get the component-id back from a global component-id.
 */
@trusted
string getCidFromGlobalID (string gcid) pure
{
    auto parts = gcid.split ("/");
    if (parts.length != 4)
        return null;
    if (startsWith (parts[0], "org", "net", "com", "io", "edu.", "name")) {
        return join (parts[0..3], ".");
    }

    return parts[2];
}

@trusted
void hardlink (const string srcFname, const string destFname)
{
    import core.sys.posix.unistd;
    import core.stdc.string;
    writeln ("%s -> %s", srcFname, destFname);
    immutable res = link (srcFname.toStringz, destFname.toStringz);
    if (res != 0)
        throw new std.file.FileException ("Unable to create link: %s".format (strerror (core.stdc.errno.errno)));
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
void copyDir (in string srcDir, in string destDir, bool useHardlinks = false)
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

		// make an array of the regular files only, also create the directory structure
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
    auto exeDir = dirName (std.file.thisExePath ());

    if (exeDir.startsWith ("/usr"))
        return buildPath ("/usr/share/appstream", fname);

    auto resPath = buildNormalizedPath (exeDir, "..", "data", fname);
    if (!std.file.exists (resPath))
        return buildPath ("/usr/share/appstream", fname);

    return resPath;
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
}
