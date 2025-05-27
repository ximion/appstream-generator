/*
 * Copyright (C) 2025 Victor Fuentes <vlinkz@snowflakeos.org>
 *
 * Based on the archlinux, alpinelinux, and freebsd backends, which are:
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) 2020 Rasmus Thomsen <oss@cogitri.dev>
 * Copyright (C) 2023 Serenity Cyber Security, LLC. Author: Gleb Popov <arrowd@FreeBSD.org>
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

module asgen.backends.nix.nixpkg;

import std.algorithm : startsWith;
import std.array : empty, join;
import std.conv : to;
import std.format : format;
import std.json : JSONValue;
import std.path : buildNormalizedPath;
import std.regex : matchFirst;
import std.string : replace, split, strip;

import asgen.backends.interfaces;
import asgen.backends.nix.nixindexutils;
import asgen.logging : logError;
import asgen.utils : escapeXml;

final class NixPackage : Package {
private:
    JSONValue pkgjson;

    string storeUrl;
    string storePath;
    string nixExe;
    string pkgattr;
    string pkgmaintainer;
    string[string] pkgContentMap;
    ubyte[][string] pkgFileData;

public:
    this (string storeUrl, string storePath, string nixExe, string attr, JSONValue[string] j)
    {
        this.storeUrl = storeUrl;
        this.storePath = storePath;
        this.nixExe = nixExe;
        this.pkgjson = j;
        this.pkgattr = attr;
    }

    @property override string name () const
    {
        return pkgattr;
    }

    @property override string ver () const
    {
        return pkgjson["version"].str();
    }

    @property override string arch () const
    {
        return pkgjson["system"].str();
    }

    @property override string maintainer () const
    {
        return pkgmaintainer;
    }

    @property override string getFilename () const
    {
        return storePath;
    }

    @property override const(string[string]) description () const
    {
        string[string] descs;
        if (auto meta = "meta" in pkgjson) {
            if (auto longDesc = "longDescription" in meta.object) {
                string longDescStr = "<p>%s</p>".format(longDesc.str().escapeXml);
                descs["C"] = longDescStr;
                descs["en"] = longDescStr;
            }
        }
        return descs;
    }

    @property override const(string[string]) summary () const
    {
        string[string] sums;
        if (auto meta = "meta" in pkgjson) {
            if (auto desc = "description" in meta.object) {
                sums["C"] = desc.str();
                sums["en"] = desc.str();
            }
        }
        return sums;
    }

    override
    ubyte[] getFileData (string fname)
    {
        if (fname in pkgFileData) {
            return pkgFileData[fname];
        }

        if (!(fname in pkgContentMap)) {
            // Hack: sometimes appstream compose requests knowingly non-existant files,
            // but if we return [] it panics. 
            return [' '];
        }

        pkgFileData[fname] = nixStoreCat(nixExe, storeUrl, pkgContentMap[fname]);
        return pkgFileData[fname];
    }

    @property override
    string[] contents ()
    {
        if (!pkgContentMap.empty) {
            return pkgContentMap.keys;
        }

        JSONValue[string] storePathCache;

        void processEntry (JSONValue entry, string currentPath, string storePath)
        {
            if (entry["type"].str == "regular") {
                if (!matchFirst(currentPath, r" ")) {
                    string fpath = "/usr" ~ currentPath;
                    // TODO(vlinkz): nixpkgs has some messed up metadata paths
                    // remove once https://github.com/NixOS/nixpkgs/pull/411205 is propagated
                    if (fpath.startsWith("/usr/share/appdata")) {
                        fpath = fpath.replace("/usr/share/appdata", "/usr/share/metainfo");
                        pkgContentMap[fpath] = storePath;
                    }
                    pkgContentMap["/usr" ~ currentPath] = storePath;
                }
            } else if (entry["type"].str == "symlink") {
                string target = buildNormalizedPath(entry["target"].str);
                if (target.startsWith("/nix/store")) {
                    auto storePathMatch = matchFirst(target, r"^(/nix/store/[^/]+)");
                    if (!storePathMatch.empty) {
                        string symStorePath = storePathMatch[1].to!string;
                        JSONValue symlinkJson;

                        if (symStorePath in storePathCache) {
                            symlinkJson = storePathCache[symStorePath];
                        } else {
                            try {
                                symlinkJson = nixStoreLs(nixExe, storeUrl, symStorePath);
                                storePathCache[symStorePath] = symlinkJson;
                            } catch (Exception e) {
                                logError("Unexpected error getting nixStoreLs JSON: %s", e.msg);
                                return;
                            }
                        }

                        string relativePath = target[symStorePath.length .. $]; // Remove store path prefix
                        relativePath = buildNormalizedPath(relativePath);
                        JSONValue targetEntry = symlinkJson;
                        if (relativePath.length > 0 && relativePath != "/") {
                            // Navigate through the JSON structure to find the target
                            auto pathParts = relativePath.strip("/").split("/");
                            foreach (i, part; pathParts) {
                                if ("entries" in targetEntry && part in targetEntry["entries"].object) {
                                    targetEntry = targetEntry["entries"].object[part];
                                } else if (targetEntry["type"].str == "symlink") {
                                    // FIXME: this is a hack to get symlinks to files inside of symlinked dirs to work.
                                    // For example:
                                    // /nix/store/pkg1/share/applications/pkg.desktop -> /nix/store/pkg2/share/applications/pkg.desktop
                                    // but /nix/store/pkg2/share/applications -> /nix/store/pkg3/applications
                                    // This will treat everything under /nix/store/pkg3/applications as under /nix/store/pkg1/share/applications
                                    // rather than just pkg.desktop
                                    string newTarget = buildNormalizedPath(targetEntry["target"].str);
                                    string newCurrent = buildNormalizedPath("/", pathParts[0 .. i].join("/"));
                                    processEntry(targetEntry, newCurrent, newTarget);
                                    return;
                                } else {
                                    logError("Could not navigate to %s in %s", relativePath, symStorePath);
                                    return;
                                }
                            }
                        }
                        processEntry(targetEntry, currentPath, target);
                    }
                }
            } else if (entry["type"].str == "directory" && "entries" in entry) {
                foreach (name, subEntry; entry["entries"].object) {
                    processEntry(subEntry, currentPath ~ "/" ~ name, storePath ~ "/" ~ name);
                }
            }
        }

        JSONValue json;
        try {
            json = nixStoreLs(nixExe, storeUrl, storePath);
        } catch (Exception e) {
            logError("Unexpected error getting nixStoreLs JSON: %s", e.msg);
            return [];
        }

        if ("entries" in json) {
            foreach (name, entry; json["entries"].object) {
                processEntry(entry, "/" ~ name, storePath ~ "/" ~ name);
            }
        }

        return pkgContentMap.keys;
    }

    override
    void finish ()
    {
    }
}
