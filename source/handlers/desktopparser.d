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

module ag.handler.desktopparser;

import std.path : baseName;
import std.uni : toLower;
import std.string : format;
import std.algorithm : startsWith;
import glib.KeyFile;
import appstream.Component;

import ag.result;


immutable DESKTOP_GROUP = "Desktop Entry";

private string getLocaleFromKey (string key)
{
    return "C";
}

private string getValue (KeyFile kf, string key)
{
    string val;
    try {
        val = kf.getString (DESKTOP_GROUP, key);
    } catch {
        val = null;
    }

    return val;
}

bool parseDesktopFile (GeneratorResult res, string fname, string data, bool ignore_nodisplay = false)
{
    auto df = new KeyFile ();
    try {
        df.loadFromData (data, -1, GKeyFileFlags.NONE);
    } catch (Exception e) {
        // there was an error
        res.addHint ("desktop-file-read-error", e.msg);
        return false;
    }

    try {
        // check if we should ignore this .desktop file
        auto dtype = df.getString (DESKTOP_GROUP, "Type");
        if (dtype.toLower () != "application") {
            // ignore this file, it isn't describing an application
            return false;
        }
    } catch {}

    try {
        auto nodisplay = df.getString (DESKTOP_GROUP, "NoDisplay");
        if ((!ignore_nodisplay) && (nodisplay.toLower () == "true")) {
                // we ignore this .desktop file, shouldn't be displayed
                return false;
        }
    } catch {}

    try {
        auto asignore = df.getString (DESKTOP_GROUP, "X-AppStream-Ignore");
        if (asignore.toLower () == "true") {
            // this .desktop file should be excluded from AppStream metadata
            return false;
        }
    } catch {
        // we don't care if non-essential tags are missing.
        // if they are not there, the file should be processed.
    }

    /* check this is a valid desktop file */
	if (!df.hasGroup (DESKTOP_GROUP)) {
        res.addHint ("desktop-file-error", format ("Desktop file '%s' is not a valid desktop file.", fname));
        return false;
	}

    // make sure we have a valid component to work on
    auto cpt = res.getComponent (fname);
    if (cpt is null) {
        auto fname_base = baseName (fname);
        cpt = new Component ();
        cpt.setId (fname_base);
        cpt.setKind (ComponentKind.DESKTOP);
        res.addComponent (cpt);
    }

    size_t dummy;
    auto keys = df.getKeys (DESKTOP_GROUP, dummy);
    foreach (string key; keys) {
        if (key.startsWith ("Name")) {
            auto locale = getLocaleFromKey (key);
            cpt.setName (getValue (df, key), locale);
        }
    }

    return true;
}

unittest
{
    import std.stdio;

    auto data = """
[Desktop Entry]
Name=FooBar
Name[de_DE]=FooBär
Summary=A foo-ish bar.
""";

    auto res = new GeneratorResult ();
    auto ret = parseDesktopFile (res, "foobar.desktop", data, false);
    assert (ret == true);
}
