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
        auto res = new GeneratorResult (Package.getId (pkg));

        // prepare a list of metadata files which interest us
        string[string] desktopFiles;
        string[] metadataFiles;
        foreach (string fname; pkg.getContentsList ()) {
            if ((fname.startsWith ("/usr/share/applications")) && (fname.endsWith (".desktop"))) {
                desktopFiles[baseName (fname)] = fname;
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

        // now process metainfo XML files
        foreach (string mfname; metadataFiles) {
            if (!mfname.endsWith (".xml"))
                continue;

            auto data = pkg.getFileData (mfname);
            auto cpt = parseMetaInfoFile (res, data);
            if (cpt is null)
                continue;

            // check if we need to extend this component's data with data from its .desktop file
            auto cid = cpt.getId ();
            if (cid.empty) {
                res.addHint ("metainfo-no-id", "general", ["fname": mfname]);
                continue;
            }

            auto dfp = (cid in desktopFiles);
            if (dfp is null) {
                // no .desktop file was found
                // finalize GCID checksum and continue
                res.updateComponentGCID (cpt, data);
                continue;
            }

            // update component with .desktop file data, ignoring NoDisplay field
            auto ddata = pkg.getFileData (*dfp);
            parseDesktopFile (res, *dfp, ddata, true);

            // update GCID checksum
            res.updateComponentGCID (cpt, data ~ ddata);

            // drop the .desktop file from the list, it has been handled
            desktopFiles.remove (cid);
        }

        // process the remaining .desktop files
        foreach (string dfname; desktopFiles.byValue ()) {
            auto data = pkg.getFileData (dfname);
            auto cpt = parseDesktopFile (res, dfname, data, false);
            if (cpt !is null)
                res.updateComponentGCID (cpt, data);
        }

        // this removes invalid components and cleans up the result
        res.finalize ();
        pkg.close ();

        // write resulting data into the database
        dcache.addGeneratorResult (DataType.XML, res);
        return res;
    }
}
