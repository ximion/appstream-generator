/*
 * Copyright (C) 2023-2025 Serenity Cyber Security, LLC
 * Author: Gleb Popov <arrowd@FreeBSD.org>
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

#include "fbsdpkgindex.h"

#include <filesystem>
#include <fstream>
#include <format>

#include "../../logging.h"
#include "../../zarchive.h"
#include "../../utils.h"

namespace ASGenerator
{

FreeBSDPackageIndex::FreeBSDPackageIndex(const std::string &dir)
    : m_rootDir(dir)
{
    if (!fs::exists(dir))
        throw std::runtime_error(std::format("Directory '{}' does not exist.", dir));
}

void FreeBSDPackageIndex::release()
{
    m_pkgCache.clear();
}

std::vector<std::shared_ptr<Package>> FreeBSDPackageIndex::loadPackages(
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    const auto pkgRoot = m_rootDir / suite;
    const auto metaFname = pkgRoot / "meta.conf";
    std::string dataFname;

    if (!fs::exists(metaFname)) {
        logError("Metadata file '{}' does not exist.", metaFname.string());
        return {};
    }

    // Parse meta.conf to find data file name
    std::ifstream metaFile(metaFname);
    std::string line;
    while (std::getline(metaFile, line)) {
        if (line.starts_with("data")) {
            // data = "data";
            auto splitResult = splitString(line, '"');
            if (splitResult.size() == 3) {
                dataFname = splitResult[1];
                break;
            }
        }
    }

    const auto dataTarFname = pkgRoot / (dataFname + ".pkg");
    if (!fs::exists(dataTarFname)) {
        logError("Package lists file '{}' does not exist.", dataTarFname.string());
        return {};
    }

    ArchiveDecompressor ad;
    ad.open(dataTarFname.string());
    logDebug("Opened: {}", dataTarFname.string());

    const auto jsonData = ad.readData(dataFname);
    const std::string jsonString(jsonData.begin(), jsonData.end());

    nlohmann::json dataJson;
    try {
        dataJson = nlohmann::json::parse(jsonString);
    } catch (const std::exception &e) {
        logError("Failed to parse JSON from '{}': {}", dataTarFname.string(), e.what());
        return {};
    }

    if (!dataJson.is_object()) {
        logError("JSON from '{}' is not an object.", dataTarFname.string());
        return {};
    }

    std::vector<std::shared_ptr<Package>> packages;

    if (dataJson.contains("packages") && dataJson["packages"].is_array()) {
        for (const auto &entry : dataJson["packages"]) {
            if (entry.is_object()) {
                auto pkg = std::make_shared<FreeBSDPackage>(pkgRoot.string(), entry);
                packages.push_back(std::static_pointer_cast<Package>(pkg));
            }
        }
    }

    return packages;
}

std::vector<std::shared_ptr<Package>> FreeBSDPackageIndex::packagesFor(
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
        m_pkgCache[id] = pkgs;
        return pkgs;
    }

    return it->second;
}

std::shared_ptr<Package> FreeBSDPackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    // Not implemented for FreeBSD backend
    return nullptr;
}

bool FreeBSDPackageIndex::hasChanges(
    std::shared_ptr<DataStore> dstore,
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    // For simplicity, always assume changes for FreeBSD
    // In a real implementation, you'd check modification times of meta.conf and data files
    return true;
}

} // namespace ASGenerator
