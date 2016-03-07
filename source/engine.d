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

module ag.engine;

import std.stdio;
import std.string;
import std.parallelism;
import std.path : buildPath;

import ag.config;
import ag.logging;
import ag.extractor;
import ag.datacache;
import ag.result;
import ag.hint;
import ag.backend.intf;
import ag.backend.debian.pkgindex;
import appstream.Component;


class Engine
{

private:
    Config conf;
    PackagesIndex pkgIndex;
    ContentsIndex contentsIndex;
    DataCache dcache;


public:

    this ()
    {
        this.conf = Config.get ();

        switch (conf.backend) {
            case Backend.Debian:
                pkgIndex = new DebianPackagesIndex ();
                break;
            default:
                throw new Exception ("No backend specified, can not continue!");
        }

        dcache = new DataCache ();
        dcache.open (buildPath (conf.workspaceDir, "cache"));
    }

    private GeneratorResult[] processSectionArch (Suite suite, string section, string arch)
    {
        pkgIndex.open (conf.archiveRoot, suite.name, section, arch);
        scope (exit) pkgIndex.close ();

        GeneratorResult[] results;

        auto mde = new DataExtractor (dcache);
        foreach (Package pkg; parallel (pkgIndex.getPackages ())) {
            auto pkid = Package.getId (pkg);
            if (dcache.packageExists (pkid))
                continue;

            auto res = mde.processPackage (pkg);
            synchronized (this) {
                info ("Processed %s, components: %s, hints: %s", res.pkid, res.componentsCount (), res.hintsCount ());
                results ~= res;
            }
        }

        return results;
    }

    void generateMetadata (string suite_name)
    {
        Suite suite;
        foreach (Suite s; conf.suites)
            if (s.name == suite_name)
                suite = s;

        Component[] cpts;
        GeneratorHint[string] hints;

        foreach (string section; suite.sections) {
            foreach (string arch; suite.architectures) {
                auto results = processSectionArch (suite, section, arch);
                foreach (GeneratorResult res; results) {
                    cpts ~= res.getComponents ();
                }
            }
        }

    }
}
