/*
 * Copyright (C) 2018-2025 Matthias Klumpp <matthias@tenstral.net>
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

#include "datainjectpkg.h"

#include <fstream>
#include <filesystem>
#include <format>

#include "logging.h"
#include "utils.h"

namespace ASGenerator
{

DataInjectPackage::DataInjectPackage(const std::string &pname, const std::string &parch, const std::string &prefix)
    : m_pkgname(pname),
      m_pkgarch(parch),
      m_fakePrefix(prefix)
{
    if (m_fakePrefix.empty())
        m_fakePrefix = "/usr";
    m_fakePrefix = Utils::normalizePath(m_fakePrefix);
}

std::string DataInjectPackage::name() const
{
    return m_pkgname;
}

std::string DataInjectPackage::ver() const
{
    return "0~0";
}

std::string DataInjectPackage::arch() const
{
    return m_pkgarch;
}

PackageKind DataInjectPackage::kind() const noexcept
{
    return PackageKind::Fake;
}

const std::unordered_map<std::string, std::string> &DataInjectPackage::description() const
{
    return m_desc;
}

std::string DataInjectPackage::getFilename()
{
    return "_local_";
}

std::string DataInjectPackage::maintainer() const
{
    return m_pkgmaintainer;
}

void DataInjectPackage::setMaintainer(const std::string &maint)
{
    m_pkgmaintainer = maint;
}

const std::string &DataInjectPackage::dataLocation() const
{
    return m_dataLocation;
}

void DataInjectPackage::setDataLocation(const std::string &value)
{
    m_dataLocation = value;
}

const std::string &DataInjectPackage::archDataLocation() const
{
    return m_archDataLocation;
}

void DataInjectPackage::setArchDataLocation(const std::string &value)
{
    m_archDataLocation = value;
}

std::vector<std::uint8_t> DataInjectPackage::getFileData(const std::string &fname)
{
    auto it = m_contents.find(fname);
    if (it == m_contents.end())
        return {};

    const std::string &localPath = it->second;
    if (localPath.empty())
        return {};

    std::vector<std::uint8_t> data;
    std::ifstream file(localPath, std::ios::binary);
    if (!file.is_open())
        return {};

    char buffer[GENERIC_BUFFER_SIZE];
    while (file.read(buffer, sizeof(buffer)) || file.gcount() > 0)
        data.insert(data.end(), buffer, buffer + file.gcount());

    return data;
}

const std::vector<std::string> &DataInjectPackage::contents()
{
    if (m_contents.empty())
        m_contentsVector.clear();

    if (!m_contents.empty())
        return m_contentsVector;

    if (m_dataLocation.empty() || !Utils::existsAndIsDir(m_dataLocation)) {
        m_contentsVector.clear();
        return m_contentsVector;
    }

    // find all icons
    const auto iconLocation = fs::path(m_dataLocation) / "icons";
    if (Utils::existsAndIsDir(iconLocation)) {
        try {
            for (const auto &entry : fs::recursive_directory_iterator(iconLocation)) {
                if (entry.is_regular_file()) {
                    const auto &iconFname = entry.path();
                    const auto extension = iconFname.extension();

                    if (extension == ".svg" || extension == ".svgz" || extension == ".png") {
                        const auto iconBasePath = fs::relative(iconFname, iconLocation);
                        const auto fakePath = fs::path("/usr/share/icons/hicolor") / iconBasePath;
                        m_contents[fakePath.string()] = iconFname.string();
                    }
                }
            }
        } catch (const fs::filesystem_error &e) {
            logError("Error scanning icon directory '{}': {}", iconLocation.string(), e.what());
        }
    } else {
        logInfo("No icons found in '{}' for injected metadata.", iconLocation.string());
    }

    // find metainfo files
    if (Utils::existsAndIsDir(m_dataLocation)) {
        try {
            for (const auto &entry : fs::directory_iterator(m_dataLocation)) {
                if (entry.is_regular_file()) {
                    const auto &miFname = entry.path();
                    if (miFname.extension() == ".xml") {
                        const auto miBasename = miFname.filename().string();
                        logDebug("Found injected metainfo [{}]: {}", "all", miBasename);
                        const auto fakePath = std::format("{}/share/metainfo/{}", m_fakePrefix, miBasename);
                        m_contents[fakePath] = miFname.string();
                    }
                }
            }
        } catch (const fs::filesystem_error &e) {
            logError("Error scanning metainfo directory '{}': {}", m_dataLocation, e.what());
        }
    }

    if (m_archDataLocation.empty() || !Utils::existsAndIsDir(m_archDataLocation))
        goto build_vector;

    // load arch-specific override metainfo files
    try {
        for (const auto &entry : fs::directory_iterator(m_archDataLocation)) {
            if (entry.is_regular_file()) {
                const auto &miFname = entry.path();
                if (miFname.extension() == ".xml") {
                    const auto miBasename = miFname.filename().string();
                    const auto fakePath = std::format("{}/share/metainfo/{}", m_fakePrefix, miBasename);

                    if (m_contents.find(fakePath) != m_contents.end()) {
                        logDebug("Found injected metainfo [{}]: {} (replacing generic one)", arch(), miBasename);
                    } else {
                        logDebug("Found injected metainfo [{}]: {}", arch(), miBasename);
                    }

                    m_contents[fakePath] = miFname.string();
                }
            }
        }
    } catch (const fs::filesystem_error &e) {
        logError("Error scanning arch-specific metainfo directory '{}': {}", m_archDataLocation, e.what());
    }

build_vector:
    m_contentsVector.clear();
    m_contentsVector.reserve(m_contents.size());
    for (const auto &[key, value] : m_contents)
        m_contentsVector.push_back(key);

    return m_contentsVector;
}

void DataInjectPackage::finish()
{
    // No-op
}

} // namespace ASGenerator
