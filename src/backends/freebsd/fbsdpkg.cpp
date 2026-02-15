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

#include "fbsdpkg.h"

#include <filesystem>
#include <fstream>
#include <memory>

#include "../../logging.h"
#include "../../zarchive.h"
#include "../../config.h"

namespace ASGenerator
{

FreeBSDPackage *FreeBSDPackage::CreateFromWorkdir(const std::string &workDir)
{
    auto *ret = new FreeBSDPackage();

    uint count = 0;
    for (const auto &entry : fs::directory_iterator(fs::path(workDir) / "pkg")) {
        if (!entry.is_regular_file())
            continue;

        if (entry.path().extension() != ".pkg")
            continue;

        count++;
        ret->m_pkgFname = entry.path();
    }

    if (ret->m_pkgFname.empty()) {
        logError("Working dir '{}' does not contain any packages under pkg/", workDir);
        return nullptr;
    }

    if (count > 1) {
        logError("Multiple packages found, but subpackages are not supported");
        return nullptr;
    }

    ret->m_stageDir = fs::path(workDir) / "stage";
    if (!fs::exists(ret->m_stageDir) || !fs::is_directory(ret->m_stageDir)) {
        logError("Stage dir '{}' does not exist or is not a directory", ret->m_stageDir.string());
        return nullptr;
    }

    auto ad = std::make_unique<ArchiveDecompressor>();
    ad->open(ret->m_pkgFname, Config::get().getTmpDir() / fs::path(ret->m_pkgFname).filename());

    const auto jsonData = ad->readData("+COMPACT_MANIFEST");
    const std::string jsonString(jsonData.begin(), jsonData.end());

    nlohmann::json dataJson;
    try {
        dataJson = nlohmann::json::parse(jsonString);
    } catch (const std::exception &e) {
        logError("Failed to parse JSON from '{}' (+COMPACT_MANIFEST): {}", ret->m_pkgFname.string(), e.what());
        return nullptr;
    }

    if (!dataJson.is_object()) {
        logError("JSON from '{}' (+COMPACT_MANIFEST) is not an object.", ret->m_pkgFname.string());
        return nullptr;
    }

    ret->m_pkgJson = dataJson;

    return ret;
}

FreeBSDPackage::FreeBSDPackage(const std::string &repoRoot, const nlohmann::json &j)
    : m_pkgJson(j),
      m_kind(PackageKind::Physical)
{
    m_pkgFname = fs::path(repoRoot) / m_pkgJson["repopath"].get<std::string>();
    m_pkgArchive = std::make_unique<ArchiveDecompressor>();
}

std::string FreeBSDPackage::name() const
{
    return m_pkgJson["name"].get<std::string>();
}

std::string FreeBSDPackage::ver() const
{
    return m_pkgJson["version"].get<std::string>();
}

std::string FreeBSDPackage::arch() const
{
    return m_pkgJson["arch"].get<std::string>();
}

std::string FreeBSDPackage::maintainer() const
{
    return m_pkgJson["maintainer"].get<std::string>();
}

std::string FreeBSDPackage::getFilename()
{
    return m_pkgFname;
}

const std::unordered_map<std::string, std::string> &FreeBSDPackage::summary() const
{
    if (m_summaryCache.empty())
        m_summaryCache["en"] = m_pkgJson["comment"].get<std::string>();

    return m_summaryCache;
}

const std::unordered_map<std::string, std::string> &FreeBSDPackage::description() const
{
    if (m_descriptionCache.empty())
        m_descriptionCache["en"] = m_pkgJson["desc"].get<std::string>();

    return m_descriptionCache;
}

std::vector<std::uint8_t> FreeBSDPackage::getFileData(const std::string &fname)
{
    if (m_isWorkdirPackage) {
        auto filePath = m_stageDir / fname;
        std::ifstream file(filePath, std::ios::binary);
        if (!file)
            throw std::runtime_error(std::format("Failed to open file from workDir: {}", filePath.string()));

        return std::vector<uint8_t>((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
    }

    std::lock_guard<std::mutex> lock(m_mutex);
    if (!m_pkgArchive->isOpen()) {
        m_pkgArchive->open(m_pkgFname, Config::get().getTmpDir() / fs::path(m_pkgFname).filename());
        m_pkgArchive->setOptimizeRepeatedReads(true);
    }

    return m_pkgArchive->readData(fname);
}

const std::vector<std::string> &FreeBSDPackage::contents()
{
    if (!m_contentsL.empty())
        return m_contentsL;

    if (m_isWorkdirPackage) {
        std::vector<std::string> ret;

        for (const auto &entry : fs::recursive_directory_iterator(m_stageDir)) {
            auto relPath = fs::relative(entry.path(), m_stageDir);
            ret.push_back(fs::path("/") / relPath);
        }

        m_contentsL = ret;
        return m_contentsL;
    }

    if (!m_pkgArchive->isOpen())
        m_pkgArchive->open(getFilename());

    m_contentsL = m_pkgArchive->readContents();
    return m_contentsL;
}

void FreeBSDPackage::finish()
{
    // No-op for FreeBSD package
}

PackageKind FreeBSDPackage::kind() const noexcept
{
    return m_kind;
}

FreeBSDPackage::FreeBSDPackage()
    : m_kind(PackageKind::Physical),
      m_isWorkdirPackage(true)
{
}

} // namespace ASGenerator
