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
#include <memory>

#include "../../logging.h"
#include "../../zarchive.h"
#include "../../config.h"

namespace ASGenerator
{

FreeBSDPackage::FreeBSDPackage(const std::string &pkgRoot, const nlohmann::json &j)
    : m_pkgjson(j),
      m_kind(PackageKind::Physical)
{
    m_pkgFname = fs::path(pkgRoot) / m_pkgjson["repopath"].get<std::string>();
    m_pkgArchive = std::make_unique<ArchiveDecompressor>();
}

std::string FreeBSDPackage::name() const
{
    return m_pkgjson["name"].get<std::string>();
}

std::string FreeBSDPackage::ver() const
{
    return m_pkgjson["version"].get<std::string>();
}

std::string FreeBSDPackage::arch() const
{
    return m_pkgjson["arch"].get<std::string>();
}

std::string FreeBSDPackage::maintainer() const
{
    return m_pkgjson["maintainer"].get<std::string>();
}

std::string FreeBSDPackage::getFilename()
{
    return m_pkgFname;
}

const std::unordered_map<std::string, std::string> &FreeBSDPackage::summary() const
{
    if (m_summaryCache.empty())
        m_summaryCache["en"] = m_pkgjson["comment"].get<std::string>();

    return m_summaryCache;
}

const std::unordered_map<std::string, std::string> &FreeBSDPackage::description() const
{
    if (m_descriptionCache.empty())
        m_descriptionCache["en"] = m_pkgjson["desc"].get<std::string>();

    return m_descriptionCache;
}

std::vector<std::uint8_t> FreeBSDPackage::getFileData(const std::string &fname)
{
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

} // namespace ASGenerator
