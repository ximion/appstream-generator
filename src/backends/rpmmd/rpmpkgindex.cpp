/*
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
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

#include "rpmpkgindex.h"

#include <filesystem>
#include <fstream>
#include <format>
#include <cstring>
#include <libxml/parser.h>

#include "../../config.h"
#include "../../logging.h"
#include "../../utils.h"
#include "../../downloader.h"
#include "../../zarchive.h"
#include "rpmutils.h"

namespace ASGenerator
{

RPMPackageIndex::RPMPackageIndex(const std::string &dir)
    : m_rootDir(dir)
{
    if (!Utils::isRemote(dir) && !fs::exists(dir))
        throw std::runtime_error(std::format("Directory '{}' does not exist.", dir));

    const auto &conf = Config::get();
    m_tmpRootDir = conf.getTmpDir() / fs::path(dir).filename();
    ;
}

RPMPackageIndex::~RPMPackageIndex() = default;

void RPMPackageIndex::release()
{
    m_pkgCache.clear();
}

static std::string getXmlStrAttr(xmlNodePtr elem, const std::string &name)
{
    if (!elem || !elem->properties)
        return {};

    for (xmlAttrPtr attr = elem->properties; attr; attr = attr->next) {
        if (attr->name && std::strcmp(reinterpret_cast<const char *>(attr->name), name.c_str()) == 0) {
            if (attr->children && attr->children->content)
                return reinterpret_cast<const char *>(attr->children->content);
        }
    }
    return {};
}

static std::string getXmlElemText(xmlNodePtr elem)
{
    if (!elem)
        return {};

    for (xmlNodePtr child = elem->children; child; child = child->next) {
        if (child->type == XML_TEXT_NODE && child->content)
            return reinterpret_cast<const char *>(child->content);
    }
    return {};
}

std::vector<std::shared_ptr<RPMPackage>> RPMPackageIndex::loadPackages(
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    // IMPORTANT: This function is *not* thread-safe! The caller needs to ensure thread-safety.

    const auto repoRoot = m_rootDir / suite / section / arch / "os";
    std::vector<std::string> primaryIndexFiles;
    std::vector<std::string> filelistFiles;

    // Download and parse repomd.xml
    const auto repoMdFname = downloadIfNecessary((repoRoot / "repodata" / "repomd.xml").string(), m_tmpRootDir);

    std::ifstream repoMdFile(repoMdFname);
    if (!repoMdFile.is_open()) {
        logError("Could not open repomd.xml file: {}", repoMdFname);
        return {};
    }

    std::string repoMdContent((std::istreambuf_iterator<char>(repoMdFile)), std::istreambuf_iterator<char>());

    // Parse index data
    xmlDocPtr doc = xmlParseMemory(repoMdContent.c_str(), static_cast<int>(repoMdContent.length()));
    if (!doc) {
        logError("Failed to parse repomd.xml");
        return {};
    }

    xmlNodePtr root = xmlDocGetRootElement(doc);
    if (!root) {
        xmlFreeDoc(doc);
        logError("No root element in repomd.xml");
        return {};
    }

    // Find primary and filelists data locations
    for (xmlNodePtr node = root->children; node; node = node->next) {
        if (node->type != XML_ELEMENT_NODE)
            continue;

        if (std::strcmp(reinterpret_cast<const char *>(node->name), "data") == 0) {
            std::string dataType = getXmlStrAttr(node, "type");

            for (xmlNodePtr child = node->children; child; child = child->next) {
                if (child->type != XML_ELEMENT_NODE)
                    continue;

                if (std::strcmp(reinterpret_cast<const char *>(child->name), "location") == 0) {
                    std::string href = getXmlStrAttr(child, "href");
                    if (!href.empty()) {
                        if (dataType == "primary")
                            primaryIndexFiles.push_back(std::move(href));
                        else if (dataType == "filelists")
                            filelistFiles.push_back(std::move(href));
                    }
                }
            }
        }
    }

    xmlFreeDoc(doc);

    if (primaryIndexFiles.empty()) {
        logWarning("No primary metadata found in repomd.xml");
        return {};
    }

    // package-id -> RPMPackage
    std::unordered_map<std::string, std::shared_ptr<RPMPackage>> pkgMap;

    // Parse primary metadata
    for (const auto &primaryFile : primaryIndexFiles) {
        const auto metaFname = downloadIfNecessary((repoRoot / primaryFile).string(), m_tmpRootDir);

        std::string data;
        if (primaryFile.ends_with(".xml")) {
            std::ifstream primaryStream(metaFname);
            if (!primaryStream.is_open()) {
                logWarning("Could not open primary metadata file: {}", metaFname);
                continue;
            }
            data = std::string((std::istreambuf_iterator<char>(primaryStream)), std::istreambuf_iterator<char>());
        } else {
            // Handle compressed files using existing decompression utility
            data = decompressFile(metaFname);
        }

        xmlDocPtr primaryDoc = xmlParseMemory(data.c_str(), static_cast<int>(data.length()));
        if (!primaryDoc) {
            logError("Failed to parse primary metadata XML");
            continue;
        }

        xmlNodePtr primaryRoot = xmlDocGetRootElement(primaryDoc);
        if (!primaryRoot) {
            xmlFreeDoc(primaryDoc);
            continue;
        }

        // Parse package entries
        for (xmlNodePtr pkgElem = primaryRoot->children; pkgElem; pkgElem = pkgElem->next) {
            if (pkgElem->type != XML_ELEMENT_NODE)
                continue;

            if (std::strcmp(reinterpret_cast<const char *>(pkgElem->name), "package") == 0) {
                // Check package type
                if (getXmlStrAttr(pkgElem, "type") != "rpm")
                    continue;

                auto pkg = std::make_shared<RPMPackage>();
                pkg->setMaintainer("None"); // Default maintainer

                std::string pkgidCS; // Package ID checksum (critical for matching)

                // Parse package children
                for (xmlNodePtr child = pkgElem->children; child; child = child->next) {
                    if (child->type != XML_ELEMENT_NODE)
                        continue;

                    const char *childName = reinterpret_cast<const char *>(child->name);

                    if (std::strcmp(childName, "name") == 0) {
                        pkg->setName(getXmlElemText(child));
                    } else if (std::strcmp(childName, "arch") == 0) {
                        pkg->setArch(getXmlElemText(child));
                    } else if (std::strcmp(childName, "summary") == 0) {
                        pkg->setSummary(getXmlElemText(child), "C");
                    } else if (std::strcmp(childName, "description") == 0) {
                        pkg->setDescription(getXmlElemText(child), "C");
                    } else if (std::strcmp(childName, "packager") == 0) {
                        pkg->setMaintainer(getXmlElemText(child));
                    } else if (std::strcmp(childName, "version") == 0) {
                        std::string epoch = getXmlStrAttr(child, "epoch");
                        std::string upstream_ver = getXmlStrAttr(child, "ver");
                        std::string rel = getXmlStrAttr(child, "rel");

                        std::string version;
                        if (epoch.empty() || epoch == "0")
                            version = std::format("{}-{}", upstream_ver, rel);
                        else
                            version = std::format("{}:{}-{}", epoch, upstream_ver, rel);

                        pkg->setVersion(version);
                    } else if (std::strcmp(childName, "location") == 0) {
                        std::string href = getXmlStrAttr(child, "href");
                        if (!href.empty())
                            pkg->setFilename((repoRoot / href).string());
                    } else if (std::strcmp(childName, "checksum") == 0) {
                        if (getXmlStrAttr(child, "pkgid") == "YES")
                            pkgidCS = getXmlElemText(child);
                    }
                }

                if (pkgidCS.empty()) {
                    logWarning(
                        "Found package '{}' in '{}' without suitable pkgid. Ignoring it.", pkg->name(), primaryFile);
                    continue;
                }

                pkgMap[pkgidCS] = std::move(pkg);
            }
        }

        xmlFreeDoc(primaryDoc);
    }

    // Parse filelists metadata
    for (const auto &filelistFile : filelistFiles) {
        const auto flistFname = downloadIfNecessary((repoRoot / filelistFile).string(), m_tmpRootDir);

        std::string data;
        if (filelistFile.ends_with(".xml")) {
            std::ifstream filelistStream(flistFname);
            if (!filelistStream.is_open()) {
                logWarning("Could not open filelist metadata file: {}", flistFname);
                continue;
            }
            data = std::string((std::istreambuf_iterator<char>(filelistStream)), std::istreambuf_iterator<char>());
        } else {
            // Handle compressed files using existing decompression utility
            data = decompressFile(flistFname);
        }

        xmlDocPtr flDoc = xmlParseMemory(data.c_str(), static_cast<int>(data.length()));
        if (!flDoc) {
            logError("Failed to parse filelist metadata XML");
            continue;
        }

        xmlNodePtr flRoot = xmlDocGetRootElement(flDoc);
        if (!flRoot) {
            xmlFreeDoc(flDoc);
            continue;
        }

        // Parse package file entries
        for (xmlNodePtr pkgElem = flRoot->children; pkgElem; pkgElem = pkgElem->next) {
            if (pkgElem->type != XML_ELEMENT_NODE)
                continue;

            if (std::strcmp(reinterpret_cast<const char *>(pkgElem->name), "package") == 0) {
                // Get package ID
                const std::string pkgid = getXmlStrAttr(pkgElem, "pkgid");
                auto pkgIt = pkgMap.find(pkgid);
                if (pkgIt == pkgMap.end())
                    continue;

                auto pkg = pkgIt->second;

                std::vector<std::string> contents;
                for (xmlNodePtr fileElem = pkgElem->children; fileElem; fileElem = fileElem->next) {
                    if (fileElem->type == XML_ELEMENT_NODE
                        && std::strcmp(reinterpret_cast<const char *>(fileElem->name), "file") == 0) {
                        std::string filePath = getXmlElemText(fileElem);
                        if (!filePath.empty())
                            contents.push_back(std::move(filePath));
                    }
                }

                pkg->setContents(contents);
            }
        }

        xmlFreeDoc(flDoc);
    }

    // Convert to vector and return
    std::vector<std::shared_ptr<RPMPackage>> packages;
    packages.reserve(pkgMap.size());
    for (const auto &[pkgid, pkg] : pkgMap)
        packages.push_back(pkg);

    logDebug("Loaded {} packages from RPM metadata", packages.size());
    return packages;
}

std::vector<std::shared_ptr<Package>> RPMPackageIndex::packagesFor(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    const std::string id = std::format("{}-{}-{}", suite, section, arch);

    // Thread-safe cache access
    std::lock_guard<std::mutex> lock(m_cacheMutex);

    auto it = m_pkgCache.find(id);
    if (it == m_pkgCache.end()) {
        auto pkgs = loadPackages(suite, section, arch);

        std::vector<std::shared_ptr<Package>> packagePtrs;
        packagePtrs.reserve(pkgs.size());
        for (const auto &pkg : pkgs)
            packagePtrs.push_back(std::static_pointer_cast<Package>(pkg));
        m_pkgCache[id] = packagePtrs;

        return packagePtrs;
    }

    return it->second;
}

std::shared_ptr<Package> RPMPackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    // FIXME: Not implemented for RPM MD backend
    return nullptr;
}

bool RPMPackageIndex::hasChanges(
    std::shared_ptr<DataStore> dstore,
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    // FIXME: We currently always assume changes for RPM MD...
    return true;
}

} // namespace ASGenerator
