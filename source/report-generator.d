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
import std.path : buildPath, buildNormalizedPath;
import std.file : mkdirRecurse;
import mustache;

import ag.config;
import ag.logging;
import ag.backend.intf;
import ag.datacache;


private alias MustacheEngine!(string) Mustache;

class ReportGenerator
{

private:
    Config conf;
    PackageIndex pkgIndex;
    DataCache dcache;

    string exportDir;
    string htmlExportDir;
    string templateDir;

    Mustache mustache;

public:

    this (DataCache dcache)
    {
        this.conf = Config.get ();

        exportDir = buildPath (conf.workspaceDir, "export");
        htmlExportDir = buildPath (exportDir, "html");

        // we need the data cache to get hint and metainfo data
        this.dcache = dcache;

        // find a suitable template directory

        // first check the workspace
        auto tdir = buildPath (conf.workspaceDir, "templates");
        tdir = getVendorTemplateDir (tdir, true);

        if (tdir is null) {
            auto exeDir = dirName (std.file.thisExePath ());
            tdir = buildNormalizedPath (exeDir, "..", "data", "templates");

            tdir = getVendorTemplateDir (tdir);
            if (tdir is null) {
                tdir = getVendorTemplateDir ("/usr/share/appstream/templates");
            }
        }

        templateDir = tdir;
        mustache.path = templateDir;
        mustache.ext = "html";
    }

    private static bool isDir (string path)
    {
        if (std.file.exists (path))
            if (std.file.isDir (path))
                return true;
        return false;
    }

    private string getVendorTemplateDir (string dir, bool allowRoot = false)
    {
        string tdir;
        if (conf.projectName !is null) {
            tdir = buildPath (dir, conf.projectName);
            if (isDir (tdir))
                return tdir;
        }
        tdir = buildPath (dir, "default");
        if (isDir (tdir))
            return tdir;
        if (allowRoot) {
            if (isDir (dir))
                return dir;
        }

        return null;
    }

    private void setupMustacheContext (Mustache.Context context)
    {
        string[string] partials;

        // this implements a very cheap way to get template inheritance
        context["partial"] = (string str) {
            str = str.strip ();
            auto blockName = "";
            if (str.startsWith ("%")) {
                auto li = str[1..$].indexOf("%");
                if (li <= 0)
                    throw new Exception ("Invalid partial: Closing '%s' missing.");
                blockName = str[1..li-1].strip ();
                str = str[li+2..$];
            }
            partials[blockName] = str;
            return "";
        };

        context["block"] = (string str) {
            str = str.strip ();
            auto blockName = "";
            if (str.startsWith ("%")) {
                auto li = str[1..$].indexOf("%");
                if (li <= 0)
                    throw new Exception ("Invalid block: Closing '%s' missing.");
                blockName = str[1..li-1].strip ();
                str = str[li+2..$];
            }
            str ~= "\n";

            auto partialCP = (blockName in partials);
            if (partialCP is null)
                return str;
            else
                return *partialCP;
        };

        context["generator_version"] = 0.1;
        context["project_name"] = conf.projectName;
    }

    private void renderPage (string pageID, string exportName, Mustache.Context context)
    {
        setupMustacheContext (context);
        writeln (htmlExportDir);
        auto fname = buildPath (htmlExportDir, exportName) ~ ".html";
        mkdirRecurse (dirName (fname));

        auto data = mustache.render (pageID, context).strip ();
        auto f = File (fname, "w");
        f.writeln (data);
    }

    void renderPagesFor (string suiteName, string section, Package[] pkgs)
    {
        if (templateDir is null) {
            logError ("Can not render HTML: No page templates found.");
            return;
        }

        foreach (pkg; pkgs) {
            // TODO
        }
    }

    void renderIndices ()
    {
        // render main overview
        auto context = new Mustache.Context;
        foreach (suite; conf.suites) {
            auto sub = context.addSubContext("suites");
            sub["suite"] = suite.name;
        }

        renderPage ("main", "index", context);
    }
}

unittest
{
    writeln ("TEST: ", "Report Generator");

    //auto rg = new ReportGenerator (null);
    //rg.renderIndices ();
}
