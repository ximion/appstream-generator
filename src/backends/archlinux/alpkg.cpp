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

#include "alpkg.h"

#include "../../logging.h"
#include "../../zarchive.h"

namespace ASGenerator
{

ArchPackage::ArchPackage()
    : m_archive(std::make_unique<ArchiveDecompressor>())
{
}

std::string ArchPackage::name() const
{
    return m_pkgname;
}

void ArchPackage::setName(const std::string &val)
{
    m_pkgname = val;
}

std::string ArchPackage::ver() const
{
    return m_pkgver;
}

void ArchPackage::setVersion(const std::string &val)
{
    m_pkgver = val;
}

std::string ArchPackage::arch() const
{
    return m_pkgarch;
}

void ArchPackage::setArch(const std::string &val)
{
    m_pkgarch = val;
}

const std::unordered_map<std::string, std::string> &ArchPackage::description() const
{
    return m_desc;
}

void ArchPackage::setFilename(const std::string &fname)
{
    m_pkgFname = fname;
}

std::string ArchPackage::getFilename()
{
    return m_pkgFname;
}

std::string ArchPackage::maintainer() const
{
    return m_pkgmaintainer;
}

void ArchPackage::setMaintainer(const std::string &maint)
{
    m_pkgmaintainer = maint;
}

void ArchPackage::setDescription(const std::string &text, const std::string &locale)
{
    m_desc[locale] = text;
}

std::vector<std::uint8_t> ArchPackage::getFileData(const std::string &fname)
{
    if (!m_archive->isOpen())
        m_archive->open(getFilename());

    return m_archive->readData(fname);
}

const std::vector<std::string> &ArchPackage::contents()
{
    return m_contentsL;
}

void ArchPackage::setContents(const std::vector<std::string> &c)
{
    m_contentsL = c;
}

void ArchPackage::finish()
{
    // No-op for Arch Linux package
}

} // namespace ASGenerator
