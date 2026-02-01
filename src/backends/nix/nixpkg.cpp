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

#include "nixpkg.h"

#include <filesystem>
#include <format>
#include <regex>

#include "../../logging.h"
#include "../../config.h"
#include "../../utils.h"
#include "nixindexutils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

NixPackage::NixPackage(
    const std::string &storeUrl,
    const std::string &storePath,
    const std::string &nixExe,
    const std::string &attr,
    const nlohmann::json &pkgjson)
    : m_pkgjson(pkgjson),
      m_storeUrl(storeUrl),
      m_storePath(storePath),
      m_nixExe(nixExe),
      m_pkgattr(attr)
{
}

std::string NixPackage::name() const
{
    return m_pkgattr;
}

std::string NixPackage::ver() const
{
    if (m_pkgjson.contains("version") && m_pkgjson["version"].is_string())
        return m_pkgjson["version"].get<std::string>();
    return "";
}

std::string NixPackage::arch() const
{
    if (m_pkgjson.contains("system") && m_pkgjson["system"].is_string())
        return m_pkgjson["system"].get<std::string>();
    return "";
}

std::string NixPackage::maintainer() const
{
    return m_pkgmaintainer;
}

std::string NixPackage::getFilename()
{
    return m_storePath;
}

const std::unordered_map<std::string, std::string> &NixPackage::summary() const
{
    if (m_summaryCache.empty()) {
        if (m_pkgjson.contains("meta") && m_pkgjson["meta"].is_object()) {
            const auto &meta = m_pkgjson["meta"];
            if (meta.contains("description") && meta["description"].is_string()) {
                m_summaryCache["C"] = meta["description"].get<std::string>();
                m_summaryCache["en"] = meta["description"].get<std::string>();
            }
        }
    }
    return m_summaryCache;
}

const std::unordered_map<std::string, std::string> &NixPackage::description() const
{
    if (m_descriptionCache.empty()) {
        if (m_pkgjson.contains("meta") && m_pkgjson["meta"].is_object()) {
            const auto &meta = m_pkgjson["meta"];
            if (meta.contains("longDescription") && meta["longDescription"].is_string()) {
                const std::string longDesc = std::format(
                    "<p>{}</p>", Utils::escapeXml(meta["longDescription"].get<std::string>()));
                m_descriptionCache["C"] = longDesc;
                m_descriptionCache["en"] = longDesc;
            }
        }
    }
    return m_descriptionCache;
}

std::vector<std::uint8_t> NixPackage::getFileData(const std::string &fname)
{
    std::lock_guard<std::mutex> lock(m_mutex);

    auto it = m_pkgFileData.find(fname);
    if (it != m_pkgFileData.end())
        return it->second;

    auto mapIt = m_pkgContentMap.find(fname);
    if (mapIt == m_pkgContentMap.end()) {
        // Hack: sometimes appstream compose requests knowingly non-existent files,
        // but if we return empty it panics.
        logDebug("Skipping non-existing file {}", fname);
        return {' '};
    }

    m_pkgFileData[fname] = nixStoreCat(m_nixExe, m_storeUrl, mapIt->second, Config::get().cacheRootDir().string());
    return m_pkgFileData[fname];
}

const std::vector<std::string> &NixPackage::contents()
{
    if (!m_contentsL.empty())
        return m_contentsL;

    std::unordered_map<std::string, nlohmann::json> storePathCache;

    std::function<void(const nlohmann::json &, const std::string &, const std::string &)> processEntry;
    processEntry = [&](const nlohmann::json &entry, const std::string &currentPath, const std::string &storePath) {
        if (!entry.is_object() || !entry.contains("type"))
            return;

        const std::string entryType = entry["type"].get<std::string>();

        if (entryType == "regular") {
            if (currentPath.find(' ') == std::string::npos) {
                std::string fpath = "/usr" + currentPath;
                if (fpath.starts_with("/usr/share/appdata/")) {
                    std::string metainfoPath = "/usr/share/metainfo/" + fpath.substr(19);
                    m_pkgContentMap[metainfoPath] = storePath;
                }
                m_pkgContentMap[fpath] = storePath;
            }
        } else if (entryType == "symlink") {
            if (!entry.contains("target"))
                return;

            std::string target = entry["target"].get<std::string>();

            if (!target.starts_with("/")) {
                fs::path symlinkDir = fs::path(storePath).parent_path();
                target = (symlinkDir / target).lexically_normal().string();
            } else {
                target = fs::path(target).lexically_normal().string();
            }

            if (target.starts_with("/nix/store")) {
                static const std::regex storePathRegex(R"(^(/nix/store/[^/]+))");
                std::smatch match;
                if (std::regex_search(target, match, storePathRegex)) {
                    std::string symStorePath = match[1].str();
                    nlohmann::json symlinkJson;

                    auto cacheIt = storePathCache.find(symStorePath);
                    if (cacheIt != storePathCache.end()) {
                        symlinkJson = cacheIt->second;
                    } else {
                        try {
                            symlinkJson = nixStoreLs(
                                m_nixExe, m_storeUrl, symStorePath, Config::get().cacheRootDir().string());
                            storePathCache[symStorePath] = symlinkJson;
                        } catch (const std::exception &e) {
                            logError("Unexpected error getting nixStoreLs JSON: {}", e.what());
                            return;
                        }
                    }

                    std::string relativePath = target.substr(symStorePath.length());
                    relativePath = fs::path(relativePath).lexically_normal().string();

                    nlohmann::json targetEntry = symlinkJson;
                    if (!relativePath.empty() && relativePath != "/") {
                        std::string pathToSplit = relativePath;
                        if (pathToSplit.starts_with("/"))
                            pathToSplit = pathToSplit.substr(1);

                        auto pathParts = Utils::splitString(pathToSplit, '/');
                        for (std::size_t i = 0; i < pathParts.size(); ++i) {
                            const auto &part = pathParts[i];
                            if (targetEntry.contains("entries") && targetEntry["entries"].contains(part)) {
                                targetEntry = targetEntry["entries"][part];
                            } else if (
                                targetEntry.contains("type") && targetEntry["type"].get<std::string>() == "symlink") {
                                // FIXME: this is a hack to get symlinks to files inside of symlinked dirs to work.
                                // For example:
                                // /nix/store/pkg1/share/applications/pkg.desktop ->
                                // /nix/store/pkg2/share/applications/pkg.desktop but /nix/store/pkg2/share/applications
                                // -> /nix/store/pkg3/share/applications. This will treat everything under
                                // /nix/store/pkg3/share/applications as under /nix/store/pkg1/share/applications rather
                                // than just pkg.desktop
                                std::string newTarget =
                                    fs::path(targetEntry["target"].get<std::string>()).lexically_normal().string();
                                std::string newCurrent = "/";
                                for (std::size_t j = 0; j < i; ++j) {
                                    newCurrent += pathParts[j];
                                    if (j < i - 1)
                                        newCurrent += "/";
                                }
                                newCurrent = fs::path(newCurrent).lexically_normal().string();
                                processEntry(targetEntry, newCurrent, newTarget);
                                return;
                            } else {
                                logError("Could not navigate to {} in {}", relativePath, symStorePath);
                                return;
                            }
                        }
                    }
                    processEntry(targetEntry, currentPath, target);
                }
            }
        } else if (entryType == "directory" && entry.contains("entries")) {
            if (currentPath == "/share" || currentPath.starts_with("/share/applications")
                || currentPath.starts_with("/share/metainfo") || currentPath.starts_with("/share/appdata")
                || currentPath.starts_with("/share/icons") || currentPath.starts_with("/share/pixmaps")) {
                for (const auto &[name, subEntry] : entry["entries"].items()) {
                    processEntry(subEntry, currentPath + "/" + name, storePath + "/" + name);
                }
            }
        }
    };

    nlohmann::json json;
    try {
        json = nixStoreLs(m_nixExe, m_storeUrl, m_storePath, Config::get().cacheRootDir().string());
    } catch (const std::exception &e) {
        logError("Unexpected error getting nixStoreLs JSON: {}", e.what());
        return m_contentsL;
    }

    if (json.contains("entries")) {
        for (const auto &[name, entry] : json["entries"].items()) {
            if (name == "share") {
                processEntry(entry, "/" + name, m_storePath + "/" + name);
            }
        }
    }

    m_contentsL.reserve(m_pkgContentMap.size());
    for (const auto &[key, value] : m_pkgContentMap) {
        m_contentsL.push_back(key);
    }

    return m_contentsL;
}

void NixPackage::finish()
{
    // No-op for Nix package
}

} // namespace ASGenerator
