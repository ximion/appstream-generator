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

module ag.extractor;

import std.stdio;
import std.string;
import ag.hint;
import ag.result;
import ag.backend.intf;
import ag.datacache;

import ag.handlers.desktopparser;
import ag.handlers.metainfoparser;

import appstream.Component;


class DataExtractor
{

private:
    Component[] cpts;
    GeneratorHint[] hints;

    DataCache dcache;

public:

    this (DataCache cache)
    {
        dcache = cache;
    }

    GeneratorResult processPackage (Package pkg)
    {
        // create a new result container
        auto res = new GeneratorResult ();

        // prepare a list of metadata files which interest us
        string[] metadataFiles;
        foreach (string fname; pkg.getContentsList ()) {
            if ((fname.startsWith ("/usr/share/applications")) && (fname.endsWith (".desktop"))) {
                metadataFiles ~= fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/appdata")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/metainfo")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
        }

        // process metainfo XML files first
        foreach (string mfname; metadataFiles) {
            if (!mfname.endsWith (".xml"))
                continue;
            writeln (mfname);
            auto data = pkg.getFileData (mfname);
            parseMetaInfoFile (res, data);
        }

        // process .desktop files to complement the XML
        foreach (string mfname; metadataFiles) {
            if (!mfname.endsWith (".desktop"))
                continue;
            writeln (mfname);
            auto data = pkg.getFileData (mfname);

            auto ignoreNoDisplay = false;
            // TODO: Determine if we have a component matching the fname already and pass it
            // to the .desktop parsing routine.
            parseDesktopFile (res, mfname, data, ignoreNoDisplay);
        }

        //writeln (Package.getId (pkg));

        pkg.close ();
        return res;
    }
}
