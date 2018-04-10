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

module asgen.backends.rpmmd.rpmpkgindex;

import std.stdio : writeln;
import std.path : buildPath;
import std.array : appender, empty;
import std.string : format;
import std.algorithm : canFind, endsWith;
import std.conv : to;
import std.xml;
static import std.file;

import asgen.logging;
import asgen.backends.interfaces;
import asgen.backends.rpmmd.rpmpkg;


final class RPMPackageIndex : PackageIndex
{

private:
    string rootDir;
    Package[][string] pkgCache;

public:

    this (string dir)
    {
        this.rootDir = dir;
        if (!std.file.exists (dir))
            throw new Exception ("Directory '%s' does not exist.", dir);
    }

    void release ()
    {
        pkgCache = null;
    }

    private void setPkgDescription (RPMPackage pkg, string pkgDesc)
    {
        if (pkgDesc is null)
            return;

        auto desc = "<p>%s</p>".format (pkgDesc);
        pkg.setDescription (desc, "C");
    }

    private RPMPackage[] loadPackages (string suite, string section, string arch)
    {
        auto repoRoot = buildPath (rootDir, suite, section, arch, "os");

        auto primaryIndexFiles = appender!(string[]);
        auto filelistFiles     = appender!(string[]);
        auto repoMdIndexContent = cast(string) std.file.read (buildPath (repoRoot, "repodata", "repomd.xml"));
        auto indexXml = new DocumentParser (repoMdIndexContent);
        indexXml.onStartTag["data"] = (ElementParser xml) {
            immutable dataType = xml.tag.attr["type"];
            if (dataType == "primary") {
                xml.onStartTag["location"] = (ElementParser x) {
                    primaryIndexFiles ~= x.tag.attr["href"];
                };
                xml.parse ();
            } else if (dataType == "filelists") {
                xml.onStartTag["location"] = (ElementParser x) {
                    filelistFiles ~= x.tag.attr["href"];
                };
                xml.parse ();
            }
        };
        indexXml.parse();

        // package-id -> RPMPackage
        RPMPackage[string] pkgMap;

        // parse the primary metadata
        foreach (ref primaryFile; primaryIndexFiles.data) {
            immutable metaFname = buildPath (repoRoot, primaryFile);
            string data;
            if (primaryFile.endsWith (".xml")) {
                data = cast(string) std.file.read (metaFname);
            } else {
                import asgen.zarchive : decompressFile;
                data = decompressFile (metaFname);
            }

            auto pkgXml = new DocumentParser (data);
            pkgXml.onStartTag["package"] = (ElementParser xml) {
                // make sure we only check RPM packages
                if (xml.tag.attr["type"] != "rpm")
                    return;

                auto pkg = new RPMPackage;
                pkg.maintainer = "None";
                xml.onEndTag["name"] = (in Element e) { pkg.name = e.text; };
                xml.onEndTag["arch"] = (in Element e) { pkg.arch = e.text; };
                xml.onEndTag["summary"] = (in Element e) { pkg.setSummary (e.text, "C"); };
                xml.onEndTag["description"] = (in Element e) { pkg.setDescription (e.text, "C"); };
                xml.onEndTag["packager"] = (in Element e) { pkg.maintainer = e.text; };

                xml.onStartTag["version"] = (ElementParser x) {
                    immutable epoch = x.tag.attr["epoch"];
                    immutable upstream_ver = x.tag.attr["ver"];
                    immutable rel = x.tag.attr["rel"];

                    if ((epoch == "0") || (epoch.empty))
                        pkg.ver = "%s-%s".format (upstream_ver, rel);
                    else
                        pkg.ver = "%s:%s-%s".format (epoch, upstream_ver, rel);
                };

                xml.onStartTag["location"] = (ElementParser x) { pkg.filename = buildPath (repoRoot, x.tag.attr["href"]); };

                string pkgidCS;
                xml.onEndTag["checksum"] = (in Element e) {
                    // we are only interested in the package-id here
                    if (e.tag.attr["pkgid"] != "YES")
                        return;
                    pkgidCS = e.text;
                };
                xml.parse ();

                if (pkgidCS.empty) {
                    logWarning ("Found package '%s' in '%s' without suitable pkgid. Ignoring it.", pkg.name, primaryFile);
                    return;
                }

                pkgMap[pkgidCS] = pkg;
            };
            pkgXml.parse();
        }
        pkgMap.rehash;

        // read the filelists
        foreach (ref filelistFile; filelistFiles.data) {
            immutable flistFname = buildPath (repoRoot, filelistFile);
            string data;
            if (filelistFile.endsWith (".xml")) {
                data = cast(string) std.file.read (flistFname);
            } else {
                import asgen.zarchive : decompressFile;
                data = decompressFile (flistFname);
            }

            auto flXml = new DocumentParser (data);
            flXml.onStartTag["package"] = (ElementParser xml) {
                immutable pkgid = xml.tag.attr["pkgid"];
                auto pkgP = pkgid in pkgMap;
                if (pkgP is null)
                    return;
                auto pkg = *pkgP;

                auto contents = appender!(string[]);
                xml.onEndTag["file"] = (in Element e) { contents ~= e.text; };
                xml.parse ();

                pkg.contents = contents.data;
            };
            flXml.parse();
        }

        return pkgMap.values;
    }

    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        immutable id = "%s-%s-%s".format (suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages (suite, section, arch);
            synchronized (this) pkgCache[id] = to!(Package[]) (pkgs);
        }

        return pkgCache[id];
    }

    Package packageForFile (string fname, string suite = null, string section = null)
    {
        return null; // FIXME: not implemented
    }

    bool hasChanges (DataStore dstore, string suite, string section, string arch)
    {
        return true;
    }
}

unittest {
    import std.algorithm.sorting : sort;
    import asgen.utils : getTestSamplesDir;

    writeln ("TEST: ", "RpmMDPackageIndex");

    auto pi = new RPMPackageIndex (buildPath (getTestSamplesDir (), "rpmmd"));
    auto pkgs = pi.loadPackages ("26", "Workstation", "x86_64");

    assert (pkgs.length == 4);
}
