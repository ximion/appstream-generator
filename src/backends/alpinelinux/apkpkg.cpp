/*
 * Copyright (C) 2020-2025 Rasmus Thomsen <oss@cogitri.dev>
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

#include "apkpkg.h"

#include <filesystem>
#include <format>

#include "../../config.h"
#include "../../downloader.h"
#include "../../utils.h"
#include "../../zarchive.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

AlpinePackage::AlpinePackage(const std::string &pkgname, const std::string &pkgver, const std::string &pkgarch)
    : m_pkgname(pkgname),
      m_pkgver(pkgver),
      m_pkgarch(pkgarch),
      m_archive(std::make_unique<ArchiveDecompressor>())
{
    const auto &conf = Config::get();
    m_tmpDir = conf.getTmpDir() / std::format("{}-{}_{}", name(), ver(), arch());
}

std::string AlpinePackage::name() const
{
    return m_pkgname;
}

void AlpinePackage::setName(const std::string &val)
{
    m_pkgname = val;
}

std::string AlpinePackage::ver() const
{
    return m_pkgver;
}

void AlpinePackage::setVersion(const std::string &val)
{
    m_pkgver = val;
}

std::string AlpinePackage::arch() const
{
    return m_pkgarch;
}

void AlpinePackage::setArch(const std::string &val)
{
    m_pkgarch = val;
}

const std::unordered_map<std::string, std::string> &AlpinePackage::description() const
{
    return m_desc;
}

void AlpinePackage::setFilename(const std::string &fname)
{
    m_pkgFname = fname;
}

std::string AlpinePackage::getFilename()
{
    if (!m_localPkgFName.empty())
        return m_localPkgFName;

    if (Utils::isRemote(m_pkgFname)) {
        std::lock_guard<std::mutex> lock(m_mutex);
        auto &dl = Downloader::get();
        const auto path = m_tmpDir / fs::path(m_pkgFname).filename();
        dl.downloadFile(m_pkgFname, path.string());
        m_localPkgFName = path.string();
        return m_localPkgFName;
    } else {
        m_localPkgFName = m_pkgFname;
        return m_localPkgFName;
    }
}

std::string AlpinePackage::maintainer() const
{
    return m_pkgmaintainer;
}

void AlpinePackage::setMaintainer(const std::string &maint)
{
    m_pkgmaintainer = maint;
}

void AlpinePackage::setDescription(const std::string &text, const std::string &locale)
{
    m_desc[locale] = text;
}

std::vector<std::uint8_t> AlpinePackage::getFileData(const std::string &fname)
{
    if (!m_archive->isOpen())
        m_archive->open(getFilename());

    return m_archive->readData(fname);
}

const std::vector<std::string> &AlpinePackage::contents()
{
    if (!m_contentsL.empty())
        return m_contentsL;

    ArchiveDecompressor ad;
    ad.open(getFilename());
    m_contentsL = ad.readContents();

    return m_contentsL;
}

void AlpinePackage::setContents(const std::vector<std::string> &c)
{
    m_contentsL = c;
}

void AlpinePackage::finish()
{
    // No-op for Alpine package
}

} // namespace ASGenerator
