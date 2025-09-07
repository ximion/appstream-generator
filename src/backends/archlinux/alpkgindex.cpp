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

#include "alpkgindex.h"

#include <filesystem>
#include <format>

#include "../../logging.h"
#include "../../zarchive.h"
#include "../../utils.h"

namespace ASGenerator
{

ArchPackageIndex::ArchPackageIndex(const std::string &dir)
    : m_rootDir(dir)
{
    if (!fs::exists(dir))
        throw std::runtime_error(std::format("Directory '{}' does not exist.", dir));
}

void ArchPackageIndex::release()
{
    m_pkgCache.clear();
}

void ArchPackageIndex::setPkgDescription(std::shared_ptr<ArchPackage> pkg, const std::string &pkgDesc)
{
    if (pkgDesc.empty())
        return;

    const std::string desc = std::format("<p>{}</p>", Utils::escapeXml(pkgDesc));
    pkg->setDescription(desc, "C");
}

std::vector<std::shared_ptr<ArchPackage>> ArchPackageIndex::loadPackages(
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    const auto pkgRoot = m_rootDir / suite / section / "os" / arch;
    const auto listsTarFname = pkgRoot / std::format("{}.files.tar.gz", section);

    if (!fs::exists(listsTarFname)) {
        logWarning("Package lists tarball '{}' does not exist.", listsTarFname.string());
        return {};
    }

    ArchiveDecompressor ad;
    ad.open(listsTarFname.string());
    logDebug("Opened: {}", listsTarFname.string());

    std::unordered_map<std::string, std::shared_ptr<ArchPackage>> pkgsMap;

    for (const auto &entry : ad.read()) {
        const auto archPkid = fs::path(entry.fname).parent_path().filename().string();

        std::shared_ptr<ArchPackage> pkg;
        auto it = pkgsMap.find(archPkid);
        if (it != pkgsMap.end()) {
            pkg = it->second;
        } else {
            pkg = std::make_shared<ArchPackage>();
            pkgsMap[archPkid] = pkg;
        }

        const auto infoBaseName = fs::path(entry.fname).filename().string();
        if (infoBaseName == "desc") {
            // we have the description file, add information to this package
            ListFile descF;
            descF.loadData(entry.data);

            pkg->setName(descF.getEntry("NAME"));
            pkg->setVersion(descF.getEntry("VERSION"));
            pkg->setArch(descF.getEntry("ARCH"));
            pkg->setMaintainer(descF.getEntry("PACKAGER"));
            pkg->setFilename((pkgRoot / descF.getEntry("FILENAME")).string());

            setPkgDescription(std::move(pkg), descF.getEntry("DESC"));

        } else if (infoBaseName == "files") {
            // we have the files list
            ListFile filesF;
            filesF.loadData(entry.data);

            const std::string filesRaw = filesF.getEntry("FILES");
            if (!filesRaw.empty()) {
                auto filesList = Utils::splitString(filesRaw, '\n');

                // add leading slash to files that don't have one
                for (auto &file : filesList) {
                    if (!file.starts_with('/')) {
                        file = '/' + file;
                    }
                }

                pkg->setContents(filesList);
            }
        }
    }

    std::vector<std::shared_ptr<ArchPackage>> result;
    result.reserve(pkgsMap.size());
    for (const auto &[pkgId, pkg] : pkgsMap) {
        if (!pkg->isValid()) {
            logWarning("Found invalid package ({})! Skipping it.", pkg->toString());
            continue;
        }
        result.push_back(pkg);
    }

    return result;
}

std::vector<std::shared_ptr<Package>> ArchPackageIndex::packagesFor(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    const std::string id = std::format("{}/{}/{}", suite, section, arch);
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

std::shared_ptr<Package> ArchPackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    // Not implemented for Arch Linux backend
    return nullptr;
}

bool ArchPackageIndex::hasChanges(
    std::shared_ptr<DataStore> dstore,
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    // For simplicity, always assume changes for Arch Linux
    // In a real implementation, you'd check modification times
    return true;
}

} // namespace ASGenerator
