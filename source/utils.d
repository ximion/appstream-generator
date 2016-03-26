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

import std.ascii : letters, digits;
import std.conv : to;
import std.random : randomSample;
import std.range : chain;
import std.algorithm : startsWith;
import std.string;
import std.stdio : writeln;


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
bool localeValid (string locale)
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
string buildCptGlobalID (string cptid, string checksum, bool allowNoChecksum = false)
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

unittest
{
    writeln ("TEST: ", "GCID");

    assert (buildCptGlobalID ("foobar.desktop", "DEADBEEF") == "f/fo/foobar.desktop/DEADBEEF");
    assert (buildCptGlobalID ("org.gnome.yelp.desktop", "DEADBEEF") == "org/gnome/yelp.desktop/DEADBEEF");
    assert (buildCptGlobalID ("noto-cjk.font", "DEADBEEF") == "n/no/noto-cjk.font/DEADBEEF");
    assert (buildCptGlobalID ("io.sample.awesomeapp.sdk", "ABAD1DEA") == "io/sample/awesomeapp.sdk/ABAD1DEA");

    assert (buildCptGlobalID ("io.sample.awesomeapp.sdk", null, true) == "io/sample/awesomeapp.sdk/");

    assert (ImageSize (80, 40).toString () == "80x40");
    assert (ImageSize (1024, 420).toInt () == 1024);
    assert (ImageSize (1024, 800) > ImageSize (64, 32));
    assert (ImageSize (48) < ImageSize (64));
}
