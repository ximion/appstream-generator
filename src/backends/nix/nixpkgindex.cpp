/*
 * Copyright (C) 2026 Victor Fuentes <vlinkz@snowflakeos.org>
 *
 * Based on the archlinux, alpinelinux, and freebsd backends, which are:
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) 2020-2025 Rasmus Thomsen <oss@cogitri.dev>
 * Copyright (C) 2023-2025 Serenity Cyber Security, LLC. Author: Gleb Popov <arrowd@FreeBSD.org>
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

#include "nixpkgindex.h"

#include <filesystem>
#include <fstream>
#include <format>
#include <algorithm>
#include <regex>

#include "../../logging.h"
#include "../../config.h"
#include "nixindexutils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

NixPackageIndex::NixPackageIndex(const std::string &storeUrl)
    : m_storeUrl(storeUrl)
{
    m_nixExe = findNixExecutable();
}

void NixPackageIndex::release()
{
    std::lock_guard<std::mutex> lock(m_cacheMutex);
    m_pkgCache.clear();
}

std::vector<std::shared_ptr<Package>> NixPackageIndex::loadPackages(
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    if (m_nixExe.empty()) {
        logError("nix binary not found. Cannot load nix packages.");
        return {};
    }

    const auto pkgRoot = Config::get().cacheRootDir() / suite / section / arch;

    std::string packagesFname;
    try {
        packagesFname = generateNixPackagesIfNecessary(m_nixExe, suite, section, (pkgRoot / "packages.json").string());
    } catch (const std::exception &e) {
        logError("Failed to generate nix packages: {}", e.what());
        return {};
    }

    // Read and parse the JSON file
    std::ifstream jsonFile(packagesFname);
    if (!jsonFile.is_open()) {
        logError("Failed to open packages file: {}", packagesFname);
        return {};
    }

    nlohmann::json packagesJson;
    try {
        jsonFile >> packagesJson;
    } catch (const std::exception &e) {
        logError("Failed to parse JSON from '{}': {}", packagesFname, e.what());
        return {};
    }

    if (!packagesJson.is_object()) {
        logError("JSON from '{}' is not an object.", packagesFname);
        return {};
    }

    logDebug("Opened: {}", packagesFname);

    std::unordered_map<std::string, NixPkgInfo> attrToPkgInfo;
    try {
        attrToPkgInfo = getInterestingNixPkgs(m_nixExe, (pkgRoot / "index").string(), m_storeUrl, packagesJson);
    } catch (const std::exception &e) {
        logError("Failed to get interesting nix packages: {}", e.what());
        return {};
    }

    std::vector<std::string> sortedAttrs;
    sortedAttrs.reserve(attrToPkgInfo.size());
    for (const auto &[attr, _] : attrToPkgInfo) {
        sortedAttrs.push_back(attr);
    }
    std::sort(sortedAttrs.begin(), sortedAttrs.end(), [](const auto &a, const auto &b) {
        return packagePriority(a) < packagePriority(b);
    });

    std::set<std::string> claimedDesktopFiles;
    std::vector<std::shared_ptr<Package>> packages;

    for (const auto &attr : sortedAttrs) {
        const auto &pkgInfo = attrToPkgInfo[attr];

        bool hasDuplicate = false;
        for (const auto &df : pkgInfo.desktopFiles) {
            if (claimedDesktopFiles.contains(df)) {
                hasDuplicate = true;
                break;
            }
        }

        if (hasDuplicate) {
            logDebug("Skipping {} - desktop files already claimed by higher priority package", attr);
            continue;
        }

        for (const auto &df : pkgInfo.desktopFiles) {
            claimedDesktopFiles.insert(df);
        }

        std::string pkgattr = attr;
        std::string pkgoutput = "out";

        auto lastDotIndex = pkgattr.rfind('.');
        if (lastDotIndex != std::string::npos) {
            pkgoutput = pkgattr.substr(lastDotIndex + 1);
            pkgattr = pkgattr.substr(0, lastDotIndex);
        }

        if (!packagesJson.contains("packages") || !packagesJson["packages"].contains(pkgattr)) {
            logError("Attribute {} not found in packages.json", pkgattr);
            continue;
        }

        const auto &entry = packagesJson["packages"][pkgattr];
        if (!entry.is_object())
            continue;

        // If output is in outputsToInstall, we don't need to state it explicitly
        std::string finalAttr = attr;
        if (entry.contains("meta") && entry["meta"].contains("outputsToInstall")) {
            const auto &outputsToInstall = entry["meta"]["outputsToInstall"];
            if (outputsToInstall.is_array()) {
                for (const auto &output : outputsToInstall) {
                    if (output.is_string() && output.get<std::string>() == pkgoutput) {
                        // Remove the output suffix
                        if (finalAttr.ends_with("." + pkgoutput))
                            finalAttr = finalAttr.substr(0, finalAttr.length() - pkgoutput.length() - 1);
                        break;
                    }
                }
            }
        }

        auto pkg = std::make_shared<NixPackage>(m_storeUrl, pkgInfo.storePath, m_nixExe, finalAttr, entry);
        packages.push_back(std::static_pointer_cast<Package>(pkg));
    }

    return packages;
}

std::vector<std::shared_ptr<Package>> NixPackageIndex::packagesFor(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    const std::string id = std::format("{}-{}-{}", suite, section, arch);

    std::lock_guard<std::mutex> lock(m_cacheMutex);

    auto it = m_pkgCache.find(id);
    if (it == m_pkgCache.end()) {
        auto pkgs = loadPackages(suite, section, arch);
        m_pkgCache[id] = pkgs;
        return pkgs;
    }

    return it->second;
}

std::shared_ptr<Package> NixPackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    // Not implemented for Nix backend
    return nullptr;
}

bool NixPackageIndex::hasChanges(
    std::shared_ptr<DataStore> dstore,
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    // For simplicity, always assume changes for Nix
    return true;
}

} // namespace ASGenerator
