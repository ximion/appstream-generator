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

module asgen.handlers.desktopparser;

import std.path : baseName;
import std.uni : toLower;
import std.string : format, indexOf, chomp, lastIndexOf, toStringz;
import std.array : split, empty;
import std.algorithm : startsWith, endsWith, strip, stripRight;
import std.stdio;
import std.typecons : scoped;

import glib.KeyFile;
import appstream.Component;
import appstream.Provided;
import appstream.Icon;
import appstream.Launchable : Launchable, LaunchableKind;
static import std.regex;

import asgen.result;
import asgen.utils;
import asgen.config : Config, FormatVersion;

private string getLocaleFromKey (string key)
{
    if (!localeValid (key))
        return null;
    auto si = key.indexOf ("[");

    // check if this key is language-specific, if not assume untranslated.
    if (si <= 0)
        return "C";

    auto locale = key[si+1..$-1];
    // drop UTF-8 suffixes
    locale = chomp (locale, ".utf-8");
    locale = chomp (locale, ".UTF-8");

    auto delim = locale.lastIndexOf ('.');
    if (delim > 0) {
        // looks like we need to drop another encoding suffix
        // (but we need to make sure it actually is one)
        auto enc = locale[delim+1..$];
        if ((enc !is null) && (enc.toLower ().startsWith ("iso"))) {
            locale = locale[0..delim];
        }
    }

    return locale;
}

private string getValue (KeyFile kf, string key)
{
    string val;
    try {
        val = kf.getString (DESKTOP_GROUP, key);
    } catch (Throwable) {
        val = null;
    }

    // some dumb .desktop files contain non-printable characters. If we are in XML mode,
    // this will hard-break the XML reader at a later point, so we need to clean this up
    // and replace these characters with a nice questionmark, so someone will clean them up.
    // TODO: Maybe even emit an issue hint if a non-printable chacater is found?
    auto re = std.regex.ctRegex!(r"[\x00\x08\x0B\x0C\x0E-\x1F]", "g");
    val = std.regex.replaceAll (val, re, "#?#");

    return val;
}

/**
 * Filter out some useless categories which we don't want to have in the
 * AppStream metadata.
 */
private string[] filterCategories (Component cpt, GeneratorResult gres, const(string[]) cats)
{
    import asgen.bindings.appstream_utils : as_utils_is_category_name;

    string[] rescats;
    foreach (string cat; cats) {
        switch (cat) {
            case "GTK":
            case "Qt":
            case "GNOME":
            case "KDE":
            case "GUI":
            case "Application":
                break;
            default:
                if (!cat.empty && !cat.toLower.startsWith ("x-")) {
                    if (as_utils_is_category_name (cat.toStringz))
                        rescats ~= cat;
                    else
                        gres.addHint (cpt, "category-name-invalid", ["category": cat]);
                }

        }
    }

    return rescats;
}

Component parseDesktopFile (GeneratorResult gres, Component cpt, string fname, string data, bool ignore_nodisplay = false)
{
    auto fnameBase = baseName (fname);

    auto df = scoped!KeyFile ();
    try {
        df.loadFromData (data, -1, GKeyFileFlags.KEEP_TRANSLATIONS);
    } catch (Exception e) {
        // there was an error
        gres.addHint (fnameBase, "desktop-file-error", e.msg);
        return null;
    }

    try {
        // check if we should ignore this .desktop file
        auto dtype = df.getString (DESKTOP_GROUP, "Type");
        if (dtype.toLower () != "application") {
            // ignore this file, it isn't describing an application
            return null;
        }
    } catch (Throwable) {}

    try {
        auto nodisplay = df.getString (DESKTOP_GROUP, "NoDisplay");
        if ((!ignore_nodisplay) && (nodisplay.toLower () == "true")) {
                // we ignore this .desktop file, it's application should not be included
                return null;
        }
    } catch (Throwable) {}

    try {
        auto asignore = df.getString (DESKTOP_GROUP, "X-AppStream-Ignore");
        if (asignore.toLower () == "true") {
            // this .desktop file should be excluded from AppStream metadata
            return null;
        }
    } catch (Throwable) {
        // we don't care if non-essential tags are missing.
        // if they are not there, the file should be processed.
    }

    try {
        auto hidden = df.getString (DESKTOP_GROUP, "NoDisplay");
        if (hidden.toLower () == "true") {
            gres.addHint (fnameBase, "desktop-file-hidden-set");
            if (!ignore_nodisplay)
                return null; // we ignore this .desktop file
        }
    } catch (Throwable) {}

    /* check this is a valid desktop file */
	if (!df.hasGroup (DESKTOP_GROUP)) {
        gres.addHint (fnameBase,
                     "desktop-file-error",
                     format ("Desktop file '%s' is not a valid desktop file.", fname));
        return null;
	}

    // make sure we have a valid component to work with
    if (cpt is null) {
        cpt = gres.getComponent (fnameBase);
        if (cpt is null) {
            // try with the shortname as well
            if (fnameBase.endsWith (".desktop")) {
                auto fnameBaseNoext = fnameBase[0..$-8];
                cpt = gres.getComponent (fnameBaseNoext);
            }
        }

        if (cpt is null) {
            cpt = new Component ();
            // strip .desktop suffix if the reverse-domain-name scheme is followed
            immutable parts = fnameBase.split (".");
            if (parts.length > 2 && isTopLevelDomain (parts[0]))
                cpt.setId (fnameBase[0..$-8]);
            else
                cpt.setId (fnameBase);

            cpt.setKind (ComponentKind.DESKTOP_APP);
            gres.addComponent (cpt);
        }
    }

    void checkDesktopString (string fieldId, string str)
    {
        if (((str.startsWith ("\"")) && (str.endsWith ("\""))) ||
            ((str.startsWith ("\'")) && (str.endsWith ("\'")))) {
                gres.addHint (cpt, "metainfo-quoted-value", ["value": str, "field": fieldId]);
            }
    }

    immutable hasExistingName = !cpt.getName ().empty;
    immutable hasExistingSummary = !cpt.getSummary ().empty;
    immutable hasExistingCategories = cpt.getCategories ().len > 0;
    immutable hasExistingMimetypes = cpt.getProvidedForKind (ProvidedKind.MIMETYPE) !is null;

    size_t dummy;
    auto keys = df.getKeys (DESKTOP_GROUP, dummy);
    foreach (string key; keys) {
        string locale;
        locale = getLocaleFromKey (key);
        if (locale is null)
            continue;

        if (key.startsWith ("Name")) {
            if (hasExistingName)
                continue;

            immutable val = getValue (df, key);
            checkDesktopString (key, val);
            /* run backend specific hooks */
            auto translations = gres.pkg.getDesktopFileTranslations (df, val);
            translations[locale] = val;
            foreach (key, value; translations)
                cpt.setName (value, key);
        } else if (key.startsWith ("Comment")) {
            if (hasExistingSummary)
                continue;

            immutable val = getValue (df, key);
            checkDesktopString (key, val);
            auto translations = gres.pkg.getDesktopFileTranslations (df, val);
            translations[locale] = val;

            foreach (ref key, ref value; translations)
                cpt.setSummary (value, key);
        } else if (key == "Categories") {
            if (hasExistingCategories)
                continue; // we already have categories set (likely from a metainfo file) - we don't append to that

            auto value = getValue (df, key);
            auto cats = value.split (";");
            cats = filterCategories (cpt, gres, cats);
            if (cats.empty)
                continue;

            foreach (ref c; cats)
                cpt.addCategory (c);
        } else if (key.startsWith ("Keywords")) {
            auto val = getValue (df, key);
            auto translations = gres.pkg.getDesktopFileTranslations (df, val);
            translations[locale] = val;

            foreach (ref key, ref value; translations) {
                auto kws = value.split (";").stripRight ("");
                if (kws.empty)
                    continue;
                cpt.setKeywords (kws, key);
            }
        } else if (key == "MimeType") {
            if (hasExistingMimetypes)
                continue;
            auto value = getValue (df, key);
            immutable mts = value.split (";");
            if (mts.empty)
                continue;

            auto prov = cpt.getProvidedForKind (ProvidedKind.MIMETYPE);
            if (prov is null) {
                prov = new Provided;
                prov.setKind (ProvidedKind.MIMETYPE);
            }

            foreach (ref mt; mts) {
                if (!mt.empty)
                    prov.addItem (mt);
            }
            cpt.addProvided (prov);
        } else if (key == "Icon") {
            // this might not be a stock icon, but for simplicity we set the stock icon type here
            // this will be sorted out by the icon handler module in a later step
            auto icon = new Icon ();
            icon.setKind (IconKind.STOCK);
            icon.setName (getValue (df, key));
            cpt.addIcon (icon);
        }
    }

    // add this .desktop file as launchable entry, if we don't have one set already
    if (cpt.getLaunchable (LaunchableKind.DESKTOP_ID) is null) {
        auto launch = new Launchable;
        launch.setKind (LaunchableKind.DESKTOP_ID);
        launch.addEntry (fnameBase);
        cpt.addLaunchable (launch);
    }

    return cpt;
}

unittest
{
    import std.stdio: writeln;
    import asgen.backends.dummy.dummypkg;
    writeln ("TEST: ", ".desktop file parser");

    auto data = "[Desktop Entry]\n" ~
                "Name=FooBar\n" ~
                "Name[de_DE]=FööBär\n" ~
                "Comment=A foo-ish bar.\n" ~
                "Keywords=Flubber;Test;Meh;\n" ~
                "Keywords[de_DE]=Goethe;Schiller;Kant;\n";

    auto pkg = new DummyPackage ("pkg", "1.0", "amd64");
    auto res = new GeneratorResult (pkg);
    auto cpt = parseDesktopFile (res, null, "foobar.desktop", data, false);
    assert (cpt !is null);

    cpt = res.getComponent ("foobar.desktop");
    assert (cpt !is null);

    assert (cpt.getName () == "FooBar");
    assert (cpt.getKeywords () == ["Flubber", "Test", "Meh"]);

    cpt.setActiveLocale ("de_DE");
    assert (cpt.getName () == "FööBär");
    assert (cpt.getKeywords () == ["Goethe", "Schiller", "Kant"]);

    // test component-id trimming
    res = new GeneratorResult (pkg);
    cpt = parseDesktopFile (res, null, "org.example.foobar.desktop", data, false);
    assert (cpt !is null);

    cpt = res.getComponent ("org.example.foobar");
    assert (cpt !is null);

    // test preexisting component
    res = new GeneratorResult (pkg);
    auto ecpt = new Component ();
    ecpt.setKind (ComponentKind.DESKTOP_APP);
    ecpt.setId ("org.example.foobar");
    ecpt.setName ("TestX", "C");
    ecpt.setSummary ("Summary of TestX", "C");
    res.addComponent (ecpt);

    cpt = parseDesktopFile (res, null, "org.example.foobar.desktop", data, false);
    assert (cpt !is null);
    cpt = res.getComponent ("org.example.foobar");
    assert (cpt !is null);

    assert (cpt.getName () == "TestX");
    assert (cpt.getSummary () == "Summary of TestX");
    assert (cpt.getKeywords () == ["Flubber", "Test", "Meh"]);

    // test launchable
    import std.string : fromStringz;

    auto launch = cpt.getLaunchable (LaunchableKind.DESKTOP_ID);
    assert (launch);
    auto launchEntries = launch.getEntries;
    assert (launchEntries.len == 1);
    assert ((cast(char*) launchEntries.index (0)).fromStringz == "org.example.foobar.desktop");
}
