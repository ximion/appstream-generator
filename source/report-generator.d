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
import std.file : mkdirRecurse, rmdirRecurse;
import std.array : empty;
import std.json;

import mustache;
import appstream.Metadata;

import ag.utils;
import ag.config;
import ag.logging;
import ag.hint;
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
    string defaultTemplateDir;

    string mediaBaseDir;
    string mediaBaseUrl;

    Mustache mustache;

    struct HintTag
    {
        string tag;
        string message;
    }

    struct HintEntry
    {
        string identifier;
        string[] archs;
        HintTag[] errors;
        HintTag[] warnings;
        HintTag[] infos;
    }

    struct MetadataEntry
    {
        ComponentKind kind;
        string identifier;
        string[] archs;
        string data;
        string iconName;
    }

    struct PkgSummary
    {
        string pkgname;
        string[] cpts;
        int infoCount;
        int warningCount;
        int errorCount;
    }

    struct DataSummary
    {
        PkgSummary[string][string] pkgSummaries;
        HintEntry[string][string] hintEntries;
        MetadataEntry[string][string][string] mdataEntries; // package -> version -> gcid -> entry
        long totalMetadata;
        long totalInfos;
        long totalWarnings;
        long totalErrors;
    }

public:

    this (DataCache dcache)
    {
        this.conf = Config.get ();

        exportDir = buildPath (conf.workspaceDir, "export");
        htmlExportDir = buildPath (exportDir, "html");
        mediaBaseDir = buildPath (exportDir, "media");
        mediaBaseUrl = conf.mediaBaseUrl;

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
        defaultTemplateDir = buildNormalizedPath (tdir, "..", "default");

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
            tdir = buildPath (dir, conf.projectName.toLower ());
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

    private string[] splitBlockData (string str, string blockType)
    {
        auto content = str.strip ();
        string blockName;
        if (content.startsWith ("{")) {
            auto li = content.indexOf("}");
            if (li <= 0)
                throw new Exception ("Invalid %s: Closing '}' missing.", blockType);
            blockName = content[1..li].strip ();
            if (li+1 >= content.length)
                content = "";
            else
                content = content[li+1..$];
        }

        if (blockName is null)
            throw new Exception ("Invalid %s: Does not have a name.", blockType);

        return [blockName, content];
    }

    private void setupMustacheContext (Mustache.Context context)
    {
        string[string] partials;

        // this implements a very cheap way to get template inheritance
        // would obviously be better if our template system supported this natively.
        context["partial"] = (string str) {
            auto split = splitBlockData (str, "partial");
            partials[split[0]] = split[1];
            return "";
        };

        context["block"] = (string str) {
            auto split = splitBlockData (str, "block");
            auto blockName = split[0];
            str = split[1] ~ "\n";

            auto partialCP = (blockName in partials);
            if (partialCP is null)
                return str;
            else
                return *partialCP;
        };

        auto time = std.datetime.Clock.currTime ();
        auto timeStr = "%d-%02d-%02d %02d:%02d [%s]".format (time.year, time.month, time.day, time.hour,time.minute, time.timezone.stdName);

        context["time"] = timeStr;
        context["generator_version"] = ag.config.generatorVersion;
        context["project_name"] = conf.projectName;
        context["root_url"] = conf.htmlBaseUrl;
    }

    private void renderPage (string pageID, string exportName, Mustache.Context context)
    {
        setupMustacheContext (context);

        auto fname = buildPath (htmlExportDir, exportName) ~ ".html";
        mkdirRecurse (dirName (fname));

        if (!std.file.exists (buildPath (templateDir, pageID ~ ".html"))) {
            if (std.file.exists (buildPath (defaultTemplateDir, pageID ~ ".html")))
                mustache.path = defaultTemplateDir;
        }

        logDebug ("Rendering HTML page: %s", exportName);
        auto data = mustache.render (pageID, context).strip ();
        auto f = File (fname, "w");
        f.writeln (data);

        // reset default template path, we might have changed it
        mustache.path = templateDir;
    }

    private void renderPagesFor (string suiteName, string section, DataSummary dsum)
    {
        if (templateDir is null) {
            logError ("Can not render HTML: No page templates found.");
            return;
        }

        logInfo ("Rendering HTML for %s/%s", suiteName, section);
        auto maintRE = std.regex.ctRegex!(r"""[àáèéëêòöøîìùñ~/\\(\\)\" ']""", "g");

        // write issue hint pages
        foreach (ref pkgname; dsum.hintEntries.byKey ()) {
            auto pkgHEntries = dsum.hintEntries[pkgname];
            auto exportName = format ("%s/%s/issues/%s", suiteName, section, pkgname);

            auto context = new Mustache.Context;
            context["suite"] = suiteName;
            context["package_name"] = pkgname;
            context["section"] = section;

            context["entries"] = (string content) {
                string res;
                foreach (ref cid; pkgHEntries.byKey ()) {
                    auto hentry = pkgHEntries[cid];
                    auto intCtx = new Mustache.Context;
                    intCtx["component_id"] = cid;

                    foreach (arch; hentry.archs) {
                        auto archSub = intCtx.addSubContext("architectures");
                        archSub["arch"] = arch;
                    }

                    if (!hentry.errors.empty)
                        intCtx["has_errors"] = ["has_errors": "yes"];
                    foreach (error; hentry.errors) {
                        auto errSub = intCtx.addSubContext("errors");
                        errSub["error_tag"] = error.tag;
                        errSub["error_description"] = error.message;
                    }

                    if (!hentry.warnings.empty)
                        intCtx["has_warnings"] = ["has_warnings": "yes"];
                    foreach (warning; hentry.warnings) {
                        auto warnSub = intCtx.addSubContext("warnings");
                        warnSub["warning_tag"] = warning.tag;
                        warnSub["warning_description"] = warning.message;
                    }

                    if (!hentry.infos.empty)
                        intCtx["has_infos"] = ["has_infos": "yes"];
                    foreach (info; hentry.infos) {
                        auto infoSub = intCtx.addSubContext("infos");
                        infoSub["info_tag"] = info.tag;
                        infoSub["info_description"] = info.message;
                    }

                    res ~= mustache.renderString (content, intCtx);
                }

                return res;
            };

            renderPage ("issues_page", exportName, context);
        }

        // write metadata info pages
        foreach (ref pkgname; dsum.mdataEntries.byKey ()) {
            auto pkgMVerEntries = dsum.mdataEntries[pkgname];
            auto exportName = format ("%s/%s/metainfo/%s", suiteName, section, pkgname);

            auto context = new Mustache.Context;
            context["suite"] = suiteName;
            context["package_name"] = pkgname;
            context["section"] = section;

            context["cpts"] = (string content) {
                string res;
                foreach (ver; pkgMVerEntries.byKey ()) {
                    auto mEntries = pkgMVerEntries[ver];

                    foreach (gcid; mEntries.byKey ()) {
                        auto mentry = mEntries[gcid];

                        auto intCtx = new Mustache.Context;
                        intCtx["component_id"] = format ("%s - %s", mentry.identifier, ver);

                        foreach (arch; mentry.archs) {
                            auto archSub = intCtx.addSubContext("architectures");
                            archSub["arch"] = arch;
                        }
                        intCtx["metadata"] = mentry.data;

                        auto cptMediaPath = buildPath (mediaBaseDir, gcid);
                        auto cptMediaUrl = buildPath (mediaBaseUrl, gcid);
                        string iconUrl;
                        switch (mentry.kind) {
                            case ComponentKind.UNKNOWN:
                                iconUrl = buildPath (conf.htmlBaseUrl, "static", "img", "no-image.png");
                                break;
                            case ComponentKind.DESKTOP:
                                if (std.file.exists (buildPath (cptMediaPath, "icons", "64x64", mentry.iconName)))
                                    iconUrl = buildPath (cptMediaUrl, "icons", "64x64", mentry.iconName);
                                else
                                    iconUrl = buildPath (conf.htmlBaseUrl, "static", "img", "no-image.png");
                                break;
                            default:
                                iconUrl = buildPath (conf.htmlBaseUrl, "static", "img", "cpt-nogui.png");
                                break;
                        }

                        intCtx["icon_url"] = iconUrl;

                        res ~= mustache.renderString (content, intCtx);
                    }

                }

                return res;
            };

            renderPage ("metainfo_page", exportName, context);
        }

        // write hint overview page
        auto hindexExportName = format ("%s/%s/issues/index", suiteName, section);
        auto hsummaryCtx = new Mustache.Context;
        hsummaryCtx["suite"] = suiteName;
        hsummaryCtx["section"] = section;

        hsummaryCtx["summaries"] = (string content) {
            string res;

            foreach (maintainer; dsum.pkgSummaries.byKey ()) {
                auto summaries = dsum.pkgSummaries[maintainer];
                auto intCtx = new Mustache.Context;
                intCtx["maintainer"] = maintainer;
                intCtx["maintainer_anchor"] = std.regex.replaceAll (maintainer, maintRE, "_");

                bool interesting = false;
                foreach (summary; summaries.byValue ()) {
                    if ((summary.infoCount == 0) && (summary.warningCount == 0) && (summary.errorCount == 0))
                        continue;
                    interesting = true;
                    auto maintSub = intCtx.addSubContext("packages");
                    maintSub["pkgname"] = summary.pkgname;

                    // again, we use this dumb hack to allow conditionals in the Mustache
                    // template.
                    if (summary.infoCount > 0)
                        maintSub["has_info_count"] =["has_count": "yes"];
                    if (summary.warningCount > 0)
                        maintSub["has_warning_count"] =["has_count": "yes"];
                    if (summary.errorCount > 0)
                        maintSub["has_error_count"] =["has_count": "yes"];

                    maintSub["info_count"] = summary.infoCount;
                    maintSub["warning_count"] = summary.warningCount;
                    maintSub["error_count"] = summary.errorCount;
                }

                if (interesting)
                    res ~= mustache.renderString (content, intCtx);
            }

            return res;
        };
        renderPage ("issues_index", hindexExportName, hsummaryCtx);

        // write metainfo overview page
        auto mindexExportName = format ("%s/%s/metainfo/index", suiteName, section);
        auto msummaryCtx = new Mustache.Context;
        msummaryCtx["suite"] = suiteName;
        msummaryCtx["section"] = section;

        msummaryCtx["summaries"] = (string content) {
            string res;

            foreach (maintainer; dsum.pkgSummaries.byKey ()) {
                auto summaries = dsum.pkgSummaries[maintainer];
                auto intCtx = new Mustache.Context;
                intCtx["maintainer"] = maintainer;
                intCtx["maintainer_anchor"] = std.regex.replaceAll (maintainer, maintRE, "_");

                intCtx["packages"] = (string content) {
                    string res;
                    foreach (summary; summaries) {
                        if (summary.cpts.length == 0)
                            continue;
                        auto subCtx = new Mustache.Context;
                        subCtx["pkgname"] = summary.pkgname;

                        foreach (cid; summary.cpts) {
                            auto cptsSub = subCtx.addSubContext("components");
                            cptsSub["cid"] = cid;
                        }

                        res ~= mustache.renderString (content, subCtx);
                    }

                    return res;
                };

                res ~= mustache.renderString (content, intCtx);
            }

            return res;
        };
        renderPage ("metainfo_index", mindexExportName, msummaryCtx);

        // render section index page
        auto secIndexExportName = format ("%s/%s/index", suiteName, section);
        auto secIndexCtx = new Mustache.Context;
        secIndexCtx["suite"] = suiteName;
        secIndexCtx["section"] = section;

        float percOne = 100.0 / cast(float) (dsum.totalMetadata + dsum.totalInfos + dsum.totalWarnings + dsum.totalErrors);
        secIndexCtx["valid_percentage"] =  dsum.totalMetadata * percOne;
        secIndexCtx["info_percentage"] = dsum.totalInfos * percOne;
        secIndexCtx["warning_percentage"] = dsum.totalWarnings * percOne;
        secIndexCtx["error_percentage"] = dsum.totalErrors * percOne;

        secIndexCtx["metainfo_count"] = dsum.totalMetadata;
        secIndexCtx["error_count"] = dsum.totalErrors;
        secIndexCtx["warning_count"] = dsum.totalWarnings;
        secIndexCtx["info_count"] = dsum.totalInfos;


        renderPage ("section_overview", secIndexExportName, secIndexCtx);
    }

    private DataSummary preprocessInformation (string suiteName, string section, Package[] pkgs)
    {
        DataSummary dsum;

        logInfo ("Collecting data about hints and available metainfo for %s/%s", suiteName, section);
        auto hintstore = HintsStorage.get ();

        auto dtype = conf.metadataType;
        auto mdata = new Metadata ();
        mdata.setParserMode (ParserMode.DISTRO);

        foreach (ref pkg; pkgs) {
            auto pkid = Package.getId (pkg);

            auto gcids = dcache.getGCIDsForPackage (pkid);
            auto hintsData = dcache.getHints (pkid);
            if ((hintsData is null) && (gcids is null))
                continue;

            PkgSummary pkgsummary;
            bool newInfo = false;

            pkgsummary.pkgname = pkg.name;
            if (pkg.maintainer in dsum.pkgSummaries) {
                auto pkgSumP = pkg.name in dsum.pkgSummaries[pkg.maintainer];
                if (pkgSumP !is null)
                    pkgsummary = *pkgSumP;
                else
                    newInfo = true;
            }

            // process component metadata for this package if there are any
            if (gcids !is null) {
                foreach (gcid; gcids) {
                    auto cid = getCidFromGlobalID (gcid);

                    // don't add the same entry multiple times for multiple versions
                    if (pkg.name in dsum.mdataEntries) {
                        if (pkg.ver in dsum.mdataEntries[pkg.name]) {
                            auto meP = gcid in dsum.mdataEntries[pkg.name][pkg.ver];
                            if (meP is null) {
                                // this component is new
                                dsum.totalMetadata += 1;
                                newInfo = true;
                            } else {
                                // we already have a component with this gcid
                                (*meP).archs ~= pkg.arch;
                                continue;
                            }
                        }
                    } else {
                        // we will add a new component
                        dsum.totalMetadata += 1;
                    }

                    MetadataEntry me;
                    me.identifier = cid;
                    me.data = dcache.getMetadata (dtype, gcid);

                    mdata.clearComponents ();
                    if (dtype == DataType.YAML)
                        mdata.parseYaml (me.data);
                    else
                        mdata.parseXml (me.data);
                    auto cpt = mdata.getComponent ();

                    if (cpt !is null) {
                        auto iconsArr = cpt.getIcons ();
                        for (uint i = 0; i < iconsArr.len; i++) {
                            import appstream.Icon;
                            auto icon = new Icon (cast (AsIcon*) iconsArr.index (i));

                            if (icon.getKind () == IconKind.CACHED) {
                                me.iconName = icon.getName ();
                                break;
                            }
                        }

                        me.kind = cpt.getKind ();
                    } else {
                        me.kind = ComponentKind.UNKNOWN;
                    }

                    me.archs ~= pkg.arch;
                    dsum.mdataEntries[pkg.name][pkg.ver][gcid] = me;
                    pkgsummary.cpts ~= format ("%s - %s", cid, pkg.ver);
                }
            }

            // process hints for this package, if there are any
            if (hintsData !is null) {
                auto hintsCpts = parseJSON (hintsData);
                hintsCpts = hintsCpts["hints"];

                foreach (cid; hintsCpts.object.byKey ()) {
                    auto jhints = hintsCpts[cid];

                    HintEntry he;
                    // don't add the same hints multiple times for multiple versions and architectures
                    if (pkg.name in dsum.hintEntries) {
                        auto heP = cid in dsum.hintEntries[pkg.name];
                        if (heP !is null) {
                            he = *heP;
                            // we already have hints for this component ID
                            he.archs ~= pkg.arch;

                            // TODO: check if we have the same hints - if not, create a new entry.
                            continue;
                        }

                        newInfo = true;
                    } else {
                        newInfo = true;
                    }

                    he.identifier = cid;

                    foreach (jhint; jhints.array) {
                        auto tag = jhint["tag"].str;
                        auto hdef = hintstore.getHintDef (tag);
                        if (hdef.tag is null) {
                            logError ("Encountered invalid tag '%s' in component '%s' of package '%s'", tag, cid, pkid);

                            // emit an internal error, invalid tags shouldn't happen
                            hdef = hintstore.getHintDef ("internal-unknown-tag");
                            assert (hdef.tag !is null);
                            jhint["vars"] = ["tag": tag];
                        }

                        // render the full message using the static template and data from the hint
                        auto context = new Mustache.Context;
                        foreach (var; jhint["vars"].object.byKey ()) {
                            context[var] = jhint["vars"][var].str;
                        }
                        auto msg = mustache.renderString (hdef.text, context);

                        // add the new hint to the right category
                        auto severity = hintstore.getSeverity (tag);
                        if (severity == HintSeverity.INFO) {
                            he.infos ~= HintTag (tag, msg);
                            pkgsummary.infoCount++;
                        } else if (severity == HintSeverity.WARNING) {
                            he.warnings ~= HintTag (tag, msg);
                            pkgsummary.warningCount++;
                        } else {
                            he.errors ~= HintTag (tag, msg);
                            pkgsummary.errorCount++;
                        }
                    }

                    if (newInfo)
                        he.archs ~= pkg.arch;

                    dsum.hintEntries[pkg.name][he.identifier] = he;
                }
            }

            dsum.pkgSummaries[pkg.maintainer][pkg.name] = pkgsummary;
            if (newInfo) {
                dsum.totalInfos += pkgsummary.infoCount;
                dsum.totalWarnings += pkgsummary.warningCount;
                dsum.totalErrors += pkgsummary.errorCount;
            }
        }

        return dsum;
    }

    private void saveStatistics (string suiteName, string section, DataSummary dsum)
    {
        auto stat = JSONValue (["suite": JSONValue (suiteName),
                                "section": JSONValue (section),
                                "totalInfos": JSONValue (dsum.totalInfos),
                                "totalWarnings": JSONValue (dsum.totalWarnings),
                                "totalErrors": JSONValue (dsum.totalErrors),
                                "totalMetadata": JSONValue (dsum.totalMetadata)]);
        dcache.addStatistics (stat);
    }

    void exportStatistics ()
    {
        logInfo ("Exporting statistical data.");

        // return all statistics we have from the database
        auto statsCollection = dcache.getStatistics ();

        auto emptyJsonObject ()
        {
            auto jobj = JSONValue (["null": 0]);
            jobj.object.remove ("null");
            return jobj;
        }

        auto emptyJsonArray ()
        {
            auto jarr = JSONValue ([0, 0]);
            jarr.array = [];
            return jarr;
        }

        // create JSON for use with e.g. Rickshaw graph
        auto smap = emptyJsonObject ();

        foreach (timestamp; statsCollection.byKey ()) {
            auto jdata = statsCollection[timestamp];
            auto js = parseJSON (jdata);
            JSONValue jstats;
            if (js.type == JSON_TYPE.ARRAY)
                jstats = js;
            else
                jstats = JSONValue ([js]);

            foreach (ref jvals; jstats.array) {
                auto suite = jvals["suite"].str;
                auto section = jvals["section"].str;

                if (suite !in smap)
                    smap.object[suite] = emptyJsonObject ();
                if (section !in smap[suite]) {
                    smap[suite].object[section] = emptyJsonObject ();
                    auto sso = smap[suite][section].object;
                    sso["errors"] = emptyJsonArray ();
                    sso["warnings"] = emptyJsonArray ();
                    sso["infos"] = emptyJsonArray ();
                    sso["metadata"] = emptyJsonArray ();
                }
                auto suiteSectionObj = smap[suite][section].object;

                auto pointErr = JSONValue ([JSONValue (timestamp), JSONValue (jvals["totalErrors"])]);
                suiteSectionObj["errors"].array ~= pointErr;

                auto pointWarn = JSONValue ([JSONValue (timestamp), JSONValue (jvals["totalWarnings"])]);
                suiteSectionObj["warnings"].array ~= pointWarn;

                auto pointInfo = JSONValue ([JSONValue (timestamp), JSONValue (jvals["totalInfos"])]);
                suiteSectionObj["infos"].array ~= pointInfo;

                auto pointMD = JSONValue ([JSONValue (timestamp), JSONValue (jvals["totalMetadata"])]);
                suiteSectionObj["metadata"].array ~= pointMD;
            }
        }

        bool compareJData (JSONValue x, JSONValue y) @trusted
        {
            return x.array[0].integer < y.array[0].integer;
        }

        // ensure our data is sorted ascending by X
        foreach (suite; smap.object.byKey ()) {
            foreach (section; smap[suite].object.byKey ()) {
                auto sso = smap[suite][section].object;

                std.algorithm.sort!(compareJData) (sso["errors"].array);
                std.algorithm.sort!(compareJData) (sso["warnings"].array);
                std.algorithm.sort!(compareJData) (sso["infos"].array);
                std.algorithm.sort!(compareJData) (sso["metadata"].array);
            }
        }

        auto fname = buildPath (htmlExportDir, "statistics.json");
        mkdirRecurse (dirName (fname));

        auto sf = File (fname, "w");
        sf.writeln (toJSON (&smap, false));
        sf.flush ();
        sf.close ();
    }

    void processFor (string suiteName, string section, Package[] pkgs)
    {
        // collect all needed information and save statistics
        auto dsum = preprocessInformation (suiteName, section, pkgs);
        saveStatistics (suiteName, section, dsum);

        // drop old pages
        auto suitSecPagesDest = buildPath (htmlExportDir, suiteName, section);
        if (std.file.exists (suitSecPagesDest))
            rmdirRecurse (suitSecPagesDest);

        // render fresh info pages
        renderPagesFor (suiteName, section, dsum);
    }

    void updateIndexPages ()
    {
        logInfo ("Updating HTML index pages and static data.");
        // render main overview
        auto context = new Mustache.Context;
        foreach (suite; conf.suites) {
            auto sub = context.addSubContext("suites");
            sub["suite"] = suite.name;

            auto secCtx = new Mustache.Context;
            secCtx["suite"] = suite.name;
            foreach (section; suite.sections) {
                auto secSub = secCtx.addSubContext("sections");
                secSub["section"] = section;
            }
            renderPage ("sections_index", format ("%s/index", suite.name), secCtx);
        }

        renderPage ("main", "index", context);

        // copy static data, if present
        auto staticSrcDir = buildPath (templateDir, "static");
        if (std.file.exists (staticSrcDir)) {
            auto staticDestDir = buildPath (htmlExportDir, "static");
            if (std.file.exists (staticDestDir))
                rmdirRecurse (staticDestDir);
            copyDir (staticSrcDir, staticDestDir);
        }
    }
}

unittest
{
    writeln ("TEST: ", "Report Generator");

    //auto rg = new ReportGenerator (null);
    //rg.renderIndices ();
}
