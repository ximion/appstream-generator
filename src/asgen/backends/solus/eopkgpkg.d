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

module asgen.backends.solus.eopkgpkg;

import std.stdio;
import std.string;
import std.array : empty, appender;
import std.path : buildNormalizedPath, baseName, dirName;
static import std.file;

import asgen.config;
import asgen.logging;
import asgen.zarchive;
import asgen.downloader : Downloader, DownloadException;
import asgen.utils : isRemote, getTextFileContents;
import asgen.backends.interfaces;

// Use selective imports for dxml to avoid naming conflicts with asgen.config.Config
import dxml.dom : DOMEntity, parseDOM, simpleXML, EntityType;

/**
 * Represents an eopkg package in the Solus distribution.
 * An eopkg package is a zip archive that contains metadata.xml and files.xml
 * describing the package, as well as an archive called install.tar.xz which contains the actual files.
 */
final class EopkgPackage : Package
{
private:
    string pkgname;
    string pkgver;
    string pkgarch;
    string pkgmaintainer;
    string[string] desc;
    string[string] summ;
    string pkgFname;
    string localPkgFname;

    string[] contentsL;

    ArchiveDecompressor archive;

    // Flag to track if we've extracted metadata already
    bool metadataExtracted;

public:
    override
    @property string name() const
    {
        return pkgname;
    }

    @property void name(string val)
    {
        pkgname = val;
    }

    override
    @property string ver() const
    {
        return pkgver;
    }

    @property void ver(string val)
    {
        pkgver = val;
    }

    override
    @property string arch() const
    {
        return pkgarch;
    }

    @property void arch(string val)
    {
        pkgarch = val;
    }

    override
    @property const(string[string]) description() const
    {
        return desc;
    }

    override
    @property const(string[string]) summary() const
    {
        return summ;
    }

    override
    @property
    string getFilename()
    {
        if (!localPkgFname.empty)
            return localPkgFname;

        if (pkgFname.isRemote)
        {
            synchronized (this)
            {
                auto conf = Config.get();
                auto dl = Downloader.get;
                // Handle eopkg format: name-version-release-distribution-arch.eopkg
                // Format a temporary filename that keeps the package identity but is unique
                immutable path = buildNormalizedPath(conf.getTmpDir(),
                    format("%s-%s-1-1-%s.eopkg.tmp", name, ver, arch));
                try
                {
                    dl.downloadFile(pkgFname, path);
                }
                catch (DownloadException e)
                {
                    logError("Unable to download: %s, reason %s", pkgFname, e.msg);
                }
                localPkgFname = path;
                return localPkgFname;
            }
        }
        else
        {
            localPkgFname = pkgFname;
            return pkgFname;
        }
    }

    @property void filename(string fname)
    {
        pkgFname = fname;
    }

    override
    @property string maintainer() const
    {
        return pkgmaintainer;
    }

    @property void maintainer(string maint)
    {
        pkgmaintainer = maint;
    }

    void setDescription(string text, string locale)
    {
        desc[locale] = text;
    }

    void setSummary(string text, string locale)
    {
        summ[locale] = text;
    }

    /**
     * Extract and parse metadata from the eopkg file.
     * In eopkg, the metadata is stored in metadata.xml and files.xml files in the root of the archive.
     */
    void extractMetadata()
    {
        if (metadataExtracted)
            return;

        if (!archive.isOpen)
            archive.open(this.getFilename);

        try
        {
            // Get the metadata XML
            auto metadataXml = cast(string) archive.readData("metadata.xml");
            auto filesXml = cast(string) archive.readData("files.xml");

            // Parse the metadata using dxml
            auto metadataDoc = parseDOM!simpleXML(metadataXml);
            auto filesDoc = parseDOM!simpleXML(filesXml);

            // Check for PISI root element
            auto pisiNode = findNode(metadataDoc, "PISI");
            if (pisiNode == DOMEntity!string.init)
                throw new Exception("PISI root element not found in metadata.xml");

            // Extract package information - find the Package node
            auto packageNode = findNode(pisiNode, "Package");
            if (packageNode == DOMEntity!string.init)
                throw new Exception("Package node not found in metadata.xml");

            // Try to get the maintainer information from the package's Source section first
            auto sourceNode = findNode(packageNode, "Source");
            if (sourceNode != DOMEntity!string.init)
            {
                auto packagerNode = findNode(sourceNode, "Packager");
                if (packagerNode != DOMEntity!string.init)
                {
                    auto emailNode = findNode(packagerNode, "Email");
                    if (emailNode != DOMEntity!string.init)
                    {
                        maintainer = nodeText(emailNode);
                    }
                }
            }
            // If maintainer wasn't found, try the top-level Source element
            else
            {
                sourceNode = findNode(pisiNode, "Source");
                if (sourceNode != DOMEntity!string.init)
                {
                    auto packagerNode = findNode(sourceNode, "Packager");
                    if (packagerNode != DOMEntity!string.init)
                    {
                        auto emailNode = findNode(packagerNode, "Email");
                        if (emailNode != DOMEntity!string.init)
                        {
                            maintainer = nodeText(emailNode);
                        }
                    }
                }
            }

            // Get name, version, and architecture
            auto nameNode = findNode(packageNode, "Name");
            if (nameNode != DOMEntity!string.init)
            {
                name = nodeText(nameNode);
            }

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
                        ver = nodeText(versionNode) ~ "-" ~ release;
                    }
                }
            }

            auto archNode = findNode(packageNode, "Architecture");
            if (archNode != DOMEntity!string.init)
            {
                arch = nodeText(archNode);
            }

            // Get summary and description with language support
            foreach (summaryNode; findNodes(packageNode, "Summary"))
            {
                auto lang = getAttribute(summaryNode, "xml:lang", "en");
                setSummary(nodeText(summaryNode), lang);
            }

            foreach (descNode; findNodes(packageNode, "Description"))
            {
                auto lang = getAttribute(descNode, "xml:lang", "en");
                setDescription(nodeText(descNode), lang);
            }

            // Extract file list from files.xml
            auto filesRootNode = findNode(filesDoc, "Files");
            auto contents = appender!(string[]);

            if (filesRootNode != DOMEntity!string.init)
            {
                foreach (fileNode; findNodes(filesRootNode, "File"))
                {
                    auto pathNode = findNode(fileNode, "Path");
                    if (pathNode != DOMEntity!string.init)
                    {
                        auto path = nodeText(pathNode);
                        // Ensure path starts with a slash
                        if (!path.startsWith("/"))
                            path = "/" ~ path;

                        // We can also get additional information about the file
                        auto typeNode = findNode(fileNode, "Type");
                        string fileType = "";
                        if (typeNode != DOMEntity!string.init)
                            fileType = nodeText(typeNode);

                        // Add the file to our content list
                        contents ~= path;
                    }
                }
            }

            contentsL = contents.data();
            metadataExtracted = true;
        }
        catch (Exception e)
        {
            logError("Failed to parse eopkg metadata: %s", e.msg);
            throw e;
        }
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

    override
    const(ubyte)[] getFileData(string fname)
    {
        if (!archive.isOpen)
            archive.open(this.getFilename);

        try
        {
            // All other files are in install.tar.xz
            // We need to extract install.tar.xz and then read files from it
            import std.path : buildPath;
            import std.file : mkdirRecurse, exists, read, remove, rmdirRecurse;
            import std.random : uniform;

            // Create a temp directory just for the install.tar.xz extraction
            auto conf = Config.get();
            auto tempDir = buildPath(conf.getTmpDir(),
                format("eopkg-%s-%s-%d", name, ver, uniform(0, int.max)));

            // Ensure temp dir exists
            if (!exists(tempDir))
                mkdirRecurse(tempDir);

            scope (exit)
            {
                // Use our helper function to clean up the temp directory
                cleanupTempDir(tempDir);
            }

            // Extract install.tar.xz to the temp directory
            auto tarPath = buildPath(tempDir, "install.tar.xz");
            auto got = archive.extractFileTo("install.tar.xz", tarPath);
            if (!got)
            {
                logError("Failed to extract install.tar.xz from package");
                return null;
            }

            // Open the extracted tarball
            auto tarArchive = new ArchiveDecompressor();
            tarArchive.open(tarPath);
            scope (exit)
            {
                if (tarArchive.isOpen)
                    tarArchive.close();
            }

            // Remove any leading slash in the file path
            auto actualPath = fname.startsWith("/") ? fname[1 .. $] : fname;

            // Try to read the file from the tarball
            try
            {
                return tarArchive.readData(actualPath);
            }
            catch (Exception e)
            {
                logWarning("File '%s' not found in install.tar.xz: %s", actualPath, e.msg);
                return null;
            }
        }
        catch (Exception e)
        {
            logError("Failed to extract file '%s' from package: %s", fname, e.msg);
            return null;
        }
    }

    @property override
    string[] contents()
    {
        if (contentsL.length == 0)
        {
            extractMetadata();
        }
        return contentsL;
    }

    @property
    void contents(string[] c)
    {
        contentsL = c;
    }

    override
    void cleanupTemp()
    {
        synchronized (this)
        {
            if (archive.isOpen)
                archive.close();
        }
    }

    /**
     * Clean up a temporary directory, ignoring any errors
     */
    private void cleanupTempDir(string path)
    {
        try
        {
            if (std.file.exists(path))
                std.file.rmdirRecurse(path);
        }
        catch (Exception e)
        {
            // Ignore errors when cleaning up
            logDebug("Unable to remove temporary directory: %s (%s)", path, e.msg);
        }
    }

    override
    void finish()
    {
        synchronized (this)
        {
            if (archive.isOpen)
                archive.close();

            try
            {
                if (pkgFname.isRemote && std.file.exists(localPkgFname))
                {
                    logDebug("Deleting temporary package file %s", localPkgFname);
                    std.file.remove(localPkgFname);
                    localPkgFname = null;
                }
            }
            catch (Exception e)
            {
                // we ignore any error
                logDebug("Unable to remove temporary package: %s (%s)", localPkgFname, e.msg);
            }
        }
    }
}
