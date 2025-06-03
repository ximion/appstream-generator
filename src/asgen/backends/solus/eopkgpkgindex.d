/*
 * Copyright (C) 2025 Solus Developers <copyright@getsol.us>
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

module asgen.backends.solus.eopkgpkgindex;

import std.stdio;
import std.path : buildPath, baseName, dirName, extension;
import std.array : appender, empty;
import std.string : format, endsWith;
import std.algorithm : canFind, startsWith, endsWith;
import std.conv : to;
static import std.file;

import asgen.logging;
import asgen.config;
import asgen.utils : escapeXml, getTextFileContents, isRemote;
import asgen.zarchive : ArchiveDecompressor, decompressFile;

// Use selective imports for dxml to avoid naming conflicts with asgen.config.Config
import dxml.dom : DOMEntity, parseDOM, simpleXML, EntityType;

import asgen.backends.interfaces;
import asgen.backends.solus.eopkgpkg;

/**
 * Index implementation for Solus eopkg packages.
 * The eopkg index is an XML file that lists all packages in a repository.
 */
final class EopkgPackageIndex : PackageIndex
{

private:
    string rootDir;
    Package[][string] pkgCache;
    string tmpRootDir;
    bool[string] indexChanged;

public:

    this(string dir)
    {
        this.rootDir = dir;
        if (!dir.isRemote && !std.file.exists(dir))
            throw new Exception(format("Directory '%s' does not exist.", dir));

        auto conf = Config.get();
        tmpRootDir = buildPath(conf.getTmpDir, dir.baseName);
    }

    void release()
    {
        pkgCache = null;
    }

    /**
     * Download a file if it's remote, or return the local path if it's already local.
     */
    private string downloadIfNecessary(string fname, string tempDir = null)
    {
        import asgen.downloader : Downloader, DownloadException;

        if (!fname.isRemote)
            return fname;

        if (tempDir.empty)
        {
            auto conf = Config.get();
            tempDir = conf.getTmpDir();
        }

        if (!std.file.exists(tempDir))
            std.file.mkdirRecurse(tempDir);

        auto dl = Downloader.get;
        immutable path = buildPath(tempDir, fname.baseName);

        try
        {
            dl.downloadFile(fname, path);
        }
        catch (DownloadException e)
        {
            logError("Unable to download: %s", e.msg);
        }

        return path;
    }

    private string getIndexPath(string rootDir, string suite)
    {
        string indexPath;

        if (rootDir.isRemote)
        {
            // For remote repositories, prefer the compressed version to save bandwidth
            indexPath = buildPath(rootDir, suite, "eopkg-index.xml.xz");
        }
        else
        {
            // For local repositories, try the uncompressed version first
            indexPath = buildPath(rootDir, suite, "eopkg-index.xml");

            // If the uncompressed file doesn't exist locally, try the compressed version
            if (!std.file.exists(indexPath))
                indexPath = buildPath(rootDir, suite, "eopkg-index.xml.xz");
        }
        return indexPath;
    }

    private string getIndexContent(string indexFname)
    {
        string indexContent;
        if (indexFname.endsWith(".xz"))
        {
            indexContent = decompressFile(indexFname);
        }
        else
        {
            indexContent = cast(string) std.file.read(indexFname);
        }
        return indexContent;
    }

    /**
     * Load packages from the eopkg repository index.
     * In Solus, the index is contained in an eopkg-index.xml.xz file.
     */
    private EopkgPackage[] loadPackages(string suite, string section, string arch)
    {
        auto indexPath = getIndexPath(rootDir, suite);

        string indexFname;
        synchronized (this)
            indexFname = downloadIfNecessary(indexPath, tmpRootDir);

        auto indexContent = getIndexContent(indexFname);

        // Parse XML index file using dxml
        auto doc = parseDOM!simpleXML(indexContent);
        auto pkgsMap = appender!(EopkgPackage[]);

        // Find PISI root element
        auto pisiNode = findNode(doc, "PISI");
        if (pisiNode == DOMEntity!string.init)
        {
            logError("Repository index does not contain a PISI root element");
            return pkgsMap.data;
        }

        // Process all Package elements in the index
        foreach (packageNode; findNodes(pisiNode, "Package"))
        {
            auto pkg = new EopkgPackage();

            // Extract basic package information
            auto nameNode = findNode(packageNode, "Name");
            string currentPkgName;
            if (nameNode != DOMEntity!string.init)
            {
                currentPkgName = nodeText(nameNode);
            }
            else
            {
                logWarning("Skipping package entry without a name.");
                continue; // Cannot process without a name
            }

            // Optimization: Skip -devel and -dbginfo subpackages, they'll never contain anything
            //               interesting.
            if (currentPkgName.endsWith("-devel") || currentPkgName.endsWith("-dbginfo"))
            {
                logDebug("Skipping development/debug package: %s", currentPkgName);
                continue;
            }

            // Set the package name if it's not skipped
            pkg.name = currentPkgName;

            // Extract version information from history
            auto historyNode = findNode(packageNode, "History");
            if (historyNode != DOMEntity!string.init)
            {
                auto updateNode = findNode(historyNode, "Update");
                if (updateNode != DOMEntity!string.init)
                {
                    auto versionNode = findNode(updateNode, "Version");
                    auto release = getAttribute(updateNode, "release", "1");
                    if (versionNode != DOMEntity!string.init)
                    {
                        pkg.ver = nodeText(versionNode) ~ "-" ~ release;
                    }
                }
            }

            // Set architecture
            auto archNode = findNode(packageNode, "Architecture");
            if (archNode != DOMEntity!string.init)
            {
                pkg.arch = nodeText(archNode);
            }

            // Get package filename
            auto packageURINode = findNode(packageNode, "PackageURI");
            if (packageURINode != DOMEntity!string.init)
            {
                auto packageURI = nodeText(packageURINode);

                // The PackageURI in eopkg-index.xml contains the relative path to the package
                // We need to preserve this path structure
                auto pkgPath = buildPath(rootDir, suite, packageURI);
                pkg.filename = pkgPath;
                logDebug("Package path: %s", pkgPath);
            }

            // Extract summary and description
            foreach (summaryNode; findNodes(packageNode, "Summary"))
            {
                auto lang = getAttribute(summaryNode, "xml:lang", "en");
                pkg.setSummary(nodeText(summaryNode), lang);
            }

            foreach (descNode; findNodes(packageNode, "Description"))
            {
                auto lang = getAttribute(descNode, "xml:lang", "en");
                pkg.setDescription(nodeText(descNode), lang);
            }

            // Get maintainer information
            auto sourceNode = findNode(packageNode, "Source");
            if (sourceNode != DOMEntity!string.init)
            {
                auto packagerNode = findNode(sourceNode, "Packager");
                if (packagerNode != DOMEntity!string.init)
                {
                    auto emailNode = findNode(packagerNode, "Email");
                    if (emailNode != DOMEntity!string.init)
                    {
                        pkg.maintainer = nodeText(emailNode);
                    }
                    else
                    {
                        pkg.maintainer = "solus@getsol.us";
                    }
                }
                else
                {
                    pkg.maintainer = "solus@getsol.us";
                }
            }
            else
            {
                pkg.maintainer = "solus@getsol.us";
            }

            // We'll extract the file list when the package is opened

            // Add the package to our list if it's valid
            if (pkg.isValid)
            {
                pkgsMap ~= pkg;
            }
            else
            {
                logError("Found an invalid package entry for '%s' (name, architecture or version is missing)."
                        ~ " Skipping it.", pkg.name);
            }
        }

        return pkgsMap.data;
    }

    /**
     * Find the first node with the given name in the document
     */
    private DOMEntity!string findNode(DOMEntity!string root, string name)
    {
        foreach (child; root.children)
        {
            if (child.type == EntityType.elementStart && child.name == name)
                return child;
        }
        DOMEntity!string nullResult;
        return nullResult;
    }

    /**
     * Find all nodes with the given name in the document
     */
    private DOMEntity!string[] findNodes(DOMEntity!string root, string name)
    {
        auto result = appender!(DOMEntity!string[]);
        foreach (child; root.children)
        {
            if (child.type == EntityType.elementStart && child.name == name)
                result ~= child;
        }
        return result.data;
    }

    /**
     * Get the text content of a node
     */
    private string nodeText(DOMEntity!string node)
    {
        foreach (child; node.children)
        {
            if (child.type == EntityType.text)
                return child.text;
        }
        return "";
    }

    /**
     * Get an attribute from a node with a default value
     */
    private string getAttribute(DOMEntity!string node, string name, string defaultValue)
    {
        foreach (attr; node.attributes)
        {
            if (attr.name == name)
                return attr.value;
        }
        return defaultValue;
    }

    Package[] packagesFor(string suite, string section, string arch, bool withLongDescs = true)
    {
        immutable id = "%s-%s-%s".format(suite, section, arch);
        if (id !in pkgCache)
        {
            auto pkgs = loadPackages(suite, section, arch);
            synchronized (this)
                pkgCache[id] = to!(Package[])(pkgs);
        }

        return pkgCache[id];
    }

    Package packageForFile(string fname, string suite = null, string section = null)
    {
        import std.path : extension;
        import std.file : exists;

        // Only handle .eopkg files
        if (fname.extension != ".eopkg")
            return null;

        if (!std.file.exists(fname))
            return null;

        try
        {
            // Create a new package for this file
            auto pkg = new EopkgPackage();
            pkg.filename = fname;

            // Extract metadata to populate fields
            pkg.extractMetadata();

            return pkg;
        }
        catch (Exception e)
        {
            logError("Failed to process package file '%s': %s", fname, e.msg);
            return null;
        }
    }

    bool hasChanges(DataStore dstore, string suite, string section, string arch)
    {
        import std.json;
        import std.datetime : SysTime;

        auto indexPath = getIndexPath(rootDir, suite);

        string indexFname;
        synchronized (this)
            indexFname = downloadIfNecessary(indexPath, tmpRootDir);

        auto indexContent = getIndexContent(indexFname);

        SysTime mtime;
        SysTime atime;
        std.file.getTimes(indexFname, atime, mtime);
        auto currentTime = mtime.toUnixTime();

        auto repoInfo = dstore.getRepoInfo(suite, section, arch);
        scope (exit)
        {
            repoInfo.object["mtime"] = JSONValue(currentTime);
            dstore.setRepoInfo(suite, section, arch, repoInfo);
        }

        if ("mtime" !in repoInfo.object)
        {
            indexChanged[indexFname] = true;
            return true;
        }

        auto pastTime = repoInfo["mtime"].integer;
        if (pastTime != currentTime)
        {
            indexChanged[indexFname] = true;
            return true;
        }

        indexChanged[indexFname] = false;
        return false;
    }
}
