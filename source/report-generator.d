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

module ag.reportgenerator;

import std.stdio;
import std.string;
import std.parallelism;
import std.path : buildPath;
import std.file : mkdirRecurse;
import mustache;

import ag.config;
import ag.backend.intf;
import ag.datacache;


class ReportGenerator
{

private:
    Config conf;
    PackagesIndex pkgIndex;
    DataCache dcache;

    string exportDir;


public:

    this ()
    {
        this.conf = Config.get ();

        // where the final metadata gets stored
        exportDir = buildPath (conf.workspaceDir, "export");

        // open cache in cache directory on workspace
        dcache = new DataCache ();
        dcache.open (buildPath (conf.workspaceDir, "cache"));
    }

}
