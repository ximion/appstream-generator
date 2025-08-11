/*
 * Copyright (C) 2020-2025 Rasmus Thomsen <oss@cogitri.dev>
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

#include "apkpkgindex.h"

#include <filesystem>
#include <format>
#include <fstream>

#include "../../config.h"
#include "../../logging.h"
#include "../../zarchive.h"
#include "../../utils.h"
#include "../../downloader.h"
#include "apkindexutils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

AlpinePackageIndex::AlpinePackageIndex(const std::string &dir)
    : m_rootDir(dir)
{
    if (!isRemote(dir) && !fs::exists(dir))
        throw std::runtime_error(std::format("Directory '{}' does not exist.", dir));

    const auto &conf = Config::get();
    m_tmpDir = conf.getTmpDir() / fs::path(dir).filename();
}

void AlpinePackageIndex::release()
{
    m_pkgCache.clear();
}

void AlpinePackageIndex::setPkgDescription(std::shared_ptr<AlpinePackage> pkg, const std::string &pkgDesc)
{
    if (pkgDesc.empty())
        return;

    const std::string desc = std::format("<p>{}</p>", escapeXml(pkgDesc));
    pkg->setDescription(desc, "C");
}

std::string AlpinePackageIndex::downloadIfNecessary(
    const std::string &apkRootPath,
    const std::string &tmpDir,
    const std::string &fileName,
    const std::string &cacheFileName)
{
    const std::string fullPath = (fs::path(apkRootPath) / fileName).string();
    const std::string cachePath = (fs::path(tmpDir) / cacheFileName).string();

    if (isRemote(fullPath)) {
        fs::create_directories(tmpDir);
        auto &dl = Downloader::get();
        dl.downloadFile(fullPath, cachePath);
        return cachePath;
    } else {
        if (fs::exists(fullPath))
            return fullPath;
        else
            throw std::runtime_error(std::format("File '{}' does not exist.", fullPath));
    }
}

std::vector<ApkIndexEntry> AlpinePackageIndex::parseApkIndex(const std::string &indexString)
{
    std::vector<ApkIndexEntry> entries;
    const auto lines = splitString(indexString, '\n');

    ApkIndexEntry currentEntry;
    for (const auto &line : lines) {
        if (line.empty()) {
            // End of package entry
            if (!currentEntry.pkgname.empty()) {
                entries.push_back(currentEntry);
                currentEntry = ApkIndexEntry{};
            }
            continue;
        }

        if (line.length() < 2 || line[1] != ':')
            continue;

        const char field = line[0];
        const std::string value = line.substr(2);

        switch (field) {
        case 'P': // Package name
            currentEntry.pkgname = value;
            break;
        case 'V': // Version
            currentEntry.pkgversion = value;
            break;
        case 'A': // Architecture
            currentEntry.arch = value;
            break;
        case 'F': // Filename
            currentEntry.archiveName = value;
            break;
        case 'm': // Maintainer
            currentEntry.maintainer = value;
            break;
        case 'T': // Description
            currentEntry.pkgdesc = value;
            break;
        default:
            // Ignore other fields
            break;
        }
    }

    // Add the last entry if not empty
    if (!currentEntry.pkgname.empty())
        entries.push_back(currentEntry);

    return entries;
}

std::vector<std::shared_ptr<Package>> AlpinePackageIndex::loadPackages(
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    const auto apkRootPath = m_rootDir / suite / section / arch;
    const auto cacheFileName = std::format("APKINDEX-{}-{}-{}.tar.gz", suite, section, arch);
    const auto indexFPath = ASGenerator::downloadIfNecessary(
        apkRootPath.string(), m_tmpDir, "APKINDEX.tar.gz", cacheFileName);

    std::unordered_map<std::string, std::shared_ptr<AlpinePackage>> pkgsMap;

    ArchiveDecompressor ad;
    ad.open(indexFPath);
    const auto indexData = ad.readData("APKINDEX");
    const std::string indexString(indexData.begin(), indexData.end());

    // Use the proper ApkIndexBlockRange from the utilities
    ApkIndexBlockRange range(indexString);
    for (const auto &pkgInfo : range) {
        const auto &fileName = pkgInfo.archiveName();

        std::shared_ptr<AlpinePackage> pkg;
        auto it = pkgsMap.find(fileName);
        if (it != pkgsMap.end()) {
            pkg = it->second;
        } else {
            pkg = std::make_shared<AlpinePackage>(pkgInfo.pkgname, pkgInfo.pkgversion, pkgInfo.arch);
            pkgsMap[fileName] = pkg;
        }

        pkg->setFilename((fs::path(m_rootDir) / suite / section / arch / fileName).string());
        pkg->setMaintainer(pkgInfo.maintainer);
        setPkgDescription(pkg, pkgInfo.pkgdesc);
    }

    // Perform a sanity check, so we will never emit invalid packages
    std::vector<std::shared_ptr<Package>> packages;
    packages.reserve(pkgsMap.size());

    for (const auto &[fileName, pkg] : pkgsMap) {
        if (!pkg->isValid()) {
            logWarning("Found invalid package ({})! Skipping it.", pkg->toString());
            continue;
        }
        packages.push_back(std::static_pointer_cast<Package>(pkg));
    }

    return packages;
}

std::vector<std::shared_ptr<Package>> AlpinePackageIndex::packagesFor(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    const std::string id = std::format("{}/{}/{}", suite, section, arch);
    auto it = m_pkgCache.find(id);
    if (it == m_pkgCache.end()) {
        auto pkgs = loadPackages(suite, section, arch);
        m_pkgCache[id] = pkgs;
        return pkgs;
    }

    return it->second;
}

std::shared_ptr<Package> AlpinePackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    // Not implemented for Alpine Linux backend
    return nullptr;
}

bool AlpinePackageIndex::hasChanges(
    std::shared_ptr<DataStore> dstore,
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    // For simplicity, always assume changes for Alpine Linux
    // In a real implementation, you'd check modification times of APKINDEX files
    return true;
}

} // namespace ASGenerator
