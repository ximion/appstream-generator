/*
 * Copyright (C) 2016 Canonical Ltd
 * Author: Iain Lane <iain.lane@canonical.com>
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

module asgen.backends.ubuntu.ubupkg;

import std.container : Array;
import std.path : buildPath;
import std.file : mkdirRecurse;
import std.conv : to;

import glib.Internationalization;
import glib.KeyFile;
import appstream.Component;

import asgen.logging;
import asgen.utils : DESKTOP_GROUP;
import asgen.backends.debian.debpkg;
import asgen.backends.interfaces;


extern (C) char *bindtextdomain (const char *domainname, const char *dirName) nothrow @nogc;

final class UbuntuPackage : DebPackage
{
    this (string pname, string pver, string parch, string globalTmpDir, ref Array!Package langpacks)
    {
        this.globalTmpDir = globalTmpDir;
        this.langpackDir = buildPath (globalTmpDir, "langpacks");
        this.localeDir = buildPath (langpackDir, "locales");
        this.langpacks = langpacks;
        super (pname, pver, parch);
    }

    override
    string[string] getDesktopFileTranslations (KeyFile desktopFile, const string text)
    {
        string langpackdomain;

        try {
            langpackdomain = desktopFile.getString (DESKTOP_GROUP,
                                                    "X-Ubuntu-Gettext-Domain");
        } catch (Throwable) {
            try {
                langpackdomain = desktopFile.getString (DESKTOP_GROUP,
                                                        "X-GNOME-Gettext-Domain");
            } catch (Throwable) {
                return null;
            }
        }

        logDebug ("%s has langpack domain %s", name, langpackdomain);

        synchronized {
            extractLangpacks ();
            return getTranslations (langpackdomain, text);
        }
    }

private:
    string globalTmpDir;
    string langpackDir;
    string localeDir;
    string[] langpackLocales;
    Array!Package langpacks;

    private void extractLangpacks ()
    {
        import std.algorithm : filter, map;
        import std.array : appender, array, split;
        import std.file : dirEntries, exists, SpanMode, readText;
        import std.parallelism : parallel;
        import std.path : baseName;
        import std.process : Pid, spawnProcess, wait;
        import std.string : splitLines, startsWith;

        auto path = buildPath (langpackDir, "usr", "share", "locale-langpack");

        if (!langpackDir.exists) {
            bool[string] extracted;

            langpackDir.mkdirRecurse ();

            foreach (ref pkg; langpacks) {
                if (pkg.name in extracted)
                    continue;

                auto upkg = to!UbuntuPackage (pkg);

                logDebug ("Extracting %s", pkg.name);
                upkg.extractPackage (langpackDir);

                extracted[pkg.name] = true;
            }

            // get back the memory
            langpacks.clear;

            auto supportedd = buildPath (langpackDir, "var", "lib", "locales", "supported.d");

            localeDir.mkdirRecurse ();
            foreach (locale; parallel (supportedd.dirEntries (SpanMode.shallow), 5))
            {
                    foreach (ref line; locale.readText.splitLines) {
                            auto components = line.split (" ");
                            auto localecharset = components[0].split (".");

                            auto outdir = buildPath (localeDir, components[0]);
                            logDebug ("Generating locale in %s", outdir);

                            auto pid = spawnProcess (["/usr/bin/localedef",
                                                      "--no-archive",
                                                      "-i",
                                                      localecharset[0],
                                                      "-c",
                                                      "-f",
                                                      components[1],
                                                      outdir]);

                            scope (exit) wait (pid);
                    }
            }
        } else {
            // we don't need it; we've already extracted the langpacks
            langpacks.clear;
        }

        if (langpackLocales is null)
            langpackLocales = localeDir.dirEntries (SpanMode.shallow)
                .filter!(f => f.isDir)
                .map!(f => f.name.baseName)
                .array;
    }

    string[string] getTranslations (const string domain, const string text)
    {
        import core.stdc.locale;
        import core.stdc.string : strdup;

        import std.c.stdlib : getenv, setenv, unsetenv;
        import std.string : fromStringz, toStringz;

        char *[char *] env;

        foreach (ref var; ["LC_ALL", "LANG", "LANGUAGE", "LC_MESSAGES"]) {
            auto value = getenv (var.toStringz);
            if (value !is null) {
                env[var.toStringz] = getenv (var.toStringz).strdup;
                unsetenv (var.toStringz);
            }
        }

        scope (exit) {
            foreach (key, val; env)
                setenv (key, val, false);
        }

        setenv ("LOCPATH", localeDir.toStringz, true);

        auto initialLocale = setlocale (LC_ALL, "");
        scope(exit) setlocale (LC_ALL, initialLocale);

        auto dir = buildPath (langpackDir,
                              "usr",
                              "share",
                              "locale-langpack");

        string[string] ret;

        foreach (ref locale; langpackLocales) {
            setlocale (LC_ALL, locale.toStringz);
            bindtextdomain (domain.toStringz, dir.toStringz);
            auto translatedtext = Internationalization.dgettext (domain, text);

            if (text != translatedtext)
                ret[locale] = translatedtext;
        }

        return ret;
    }
}
