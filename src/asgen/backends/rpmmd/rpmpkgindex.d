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
import std.path : buildPath, baseName;
import std.array : appender, empty;
import std.string : format;
import std.algorithm : canFind, endsWith;
import std.conv : to;
import dxml.dom : parseDOM, EntityType;
static import std.file;

import asgen.logging;
import asgen.config;
import asgen.utils : escapeXml, getTextFileContents, isRemote;

import asgen.backends.interfaces;
import asgen.backends.rpmmd.rpmpkg;
import asgen.backends.rpmmd.rpmutils : downloadIfNecessary;

final class RPMPackageIndex : PackageIndex {

private:
    string rootDir;
    Package[][string] pkgCache;
    string tmpRootDir;

public:

    this (string dir)
    {
        this.rootDir = dir;
        if (!dir.isRemote && !std.file.exists(dir))
            throw new Exception("Directory '%s' does not exist.".format(dir));

        auto conf = Config.get();
        tmpRootDir = buildPath(conf.getTmpDir, dir.baseName);
    }

    void release ()
    {
        pkgCache = null;
    }

    private void setPkgDescription (RPMPackage pkg, string pkgDesc)
    {
        if (pkgDesc is null)
            return;

        auto desc = "<p>%s</p>".format(pkgDesc);
        pkg.setDescription(desc, "C");
    }

    static private string getXmlStrAttr(T)(T elem, string name)
    {
        foreach (attr; elem.attributes) {
            if (attr.name == name)
                return attr.value;
        }
        return null;
    }

    static private string getXmlElemText(T)(T elem)
    {
        foreach (child; elem.children) {
            if (child.type == EntityType.text)
                return child.text;
        }
        return null;
    }

    private RPMPackage[] loadPackages (string suite, string section, string arch)
    {
        auto repoRoot = buildPath(rootDir, suite, section, arch, "os");
        auto primaryIndexFiles = appender!(string[]);
        auto filelistFiles = appender!(string[]);

        string repoMdFname;
        synchronized (this)
            repoMdFname = downloadIfNecessary(buildPath(repoRoot, "repodata", "repomd.xml"), tmpRootDir);

        immutable repoMdIndexContent = cast(string) std.file.read(repoMdFname);

        // parse index data
        auto indexDoc = parseDOM(repoMdIndexContent);
        foreach (dataElem; indexDoc.children[0].children) {
            // iterate over all "data" elements
            if (dataElem.type != EntityType.elementStart || dataElem.name != "data")
                continue;

            string dataType = getXmlStrAttr(dataElem, "type");
            foreach (locationElem; dataElem.children) {
                if (locationElem.type != EntityType.elementStart && locationElem.type != EntityType.elementEmpty)
                    continue;
                if (locationElem.name != "location")
                    continue;

                string href = getXmlStrAttr(locationElem, "href");
                if (dataType == "primary") {
                    primaryIndexFiles ~= href;
                } else if (dataType == "filelists") {
                    filelistFiles ~= href;
                }
            }
        }

        // package-id -> RPMPackage
        RPMPackage[string] pkgMap;

        // parse the primary metadata
        foreach (ref primaryFile; primaryIndexFiles.data) {
            string metaFname;
            synchronized(this)
                metaFname = downloadIfNecessary(buildPath(repoRoot, primaryFile), tmpRootDir);

            string data;
            if (primaryFile.endsWith(".xml")) {
                data = cast(string) std.file.read(metaFname);
            } else {
                import asgen.zarchive : decompressFile;

                data = decompressFile(metaFname);
            }

            auto pkgXml = parseDOM(data);
            foreach (pkgElem; pkgXml.children[0].children) {
                if (pkgElem.type != EntityType.elementStart || pkgElem.name != "package")
                    continue;

                if (getXmlStrAttr(pkgElem, "type") != "rpm")
                    continue;

                auto pkg = new RPMPackage;
                pkg.maintainer = "None";

                string pkgidCS;
                foreach (child; pkgElem.children) {
                    if (child.type != EntityType.elementStart && child.type != EntityType.elementEmpty)
                        continue;

                    switch (child.name) {
                        case "name":
                            pkg.name = getXmlElemText(child);
                            break;
                        case "arch":
                            pkg.arch = getXmlElemText(child);
                            break;
                        case "summary":
                            pkg.setSummary(getXmlElemText(child), "C");
                            break;
                        case "description":
                            pkg.setDescription(getXmlElemText(child), "C");
                            break;
                        case "packager":
                            pkg.maintainer = getXmlElemText(child);
                            break;
                        case "version":
                            string epoch = getXmlStrAttr(child, "epoch");
                            string upstream_ver = getXmlStrAttr(child, "ver");
                            string rel = getXmlStrAttr(child, "rel");
                            pkg.ver = epoch.empty || epoch == "0" ? "%s-%s".format(upstream_ver, rel) : "%s:%s-%s".format(epoch, upstream_ver, rel);
                            break;
                        case "location":
                            pkg.filename = buildPath(repoRoot, getXmlStrAttr(child, "href"));
                            break;
                        case "checksum":
                            if (getXmlStrAttr(child, "pkgid") == "YES") {
                                pkgidCS = getXmlElemText(child);
                            }
                            break;
                        default:
                            continue;
                    }
                }

                if (pkgidCS.empty) {
                    logWarning("Found package '%s' in '%s' without suitable pkgid. Ignoring it.", pkg.name, primaryFile);
                    continue;
                }

                pkgMap[pkgidCS] = pkg;
            }
        }
        pkgMap.rehash();

        // read the filelists
        foreach (ref filelistFile; filelistFiles.data) {
            string flistFname;
            synchronized (this)
                flistFname = downloadIfNecessary(buildPath(repoRoot, filelistFile), tmpRootDir);

            string data;
            if (filelistFile.endsWith(".xml")) {
                data = cast(string) std.file.read(flistFname);
            } else {
                import asgen.zarchive : decompressFile;

                data = decompressFile(flistFname);
            }

            auto flDoc = parseDOM(data);
            foreach (pkgElem; flDoc.children[0].children) {
                if (pkgElem.type != EntityType.elementStart || pkgElem.name != "package")
                    continue;

                immutable pkgid = getXmlStrAttr(pkgElem, "pkgid");
                auto pkgP = pkgid in pkgMap;
                if (pkgP is null)
                    continue;
                auto pkg = *pkgP;

                auto contents = appender!(string[]);
                foreach (fileElem; pkgElem.children) {
                    if (fileElem.type == EntityType.elementStart && fileElem.name == "file")
                        contents ~= getXmlElemText(fileElem);
                }

                pkg.contents = contents.data;
            }
        }

        return pkgMap.values;
    }

    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        immutable id = "%s-%s-%s".format(suite, section, arch);
        if (id !in pkgCache) {
            auto pkgs = loadPackages(suite, section, arch);
            synchronized (this)
                pkgCache[id] = to!(Package[])(pkgs);
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

    writeln("TEST: ", "RpmMDPackageIndex");

    auto pi = new RPMPackageIndex(buildPath(getTestSamplesDir(), "rpmmd"));
    auto pkgs = pi.loadPackages("26", "Workstation", "x86_64");

    assert(pkgs.length == 4);
}
