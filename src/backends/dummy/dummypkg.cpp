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

#include "dummypkg.h"

#include "../../logging.h"

namespace ASGenerator
{

DummyPackage::DummyPackage(const std::string &pname, const std::string &pver, const std::string &parch)
    : m_name(pname),
      m_version(pver),
      m_arch(parch),
      m_kind(PackageKind::Physical),
      m_contents({"NOTHING1", "NOTHING2"})
{
}

std::string DummyPackage::name() const
{
    return m_name;
}

std::string DummyPackage::ver() const
{
    return m_version;
}

std::string DummyPackage::arch() const
{
    return m_arch;
}

std::string DummyPackage::maintainer() const
{
    return m_maintainer;
}

const std::unordered_map<std::string, std::string> &DummyPackage::description() const
{
    return m_description;
}

std::string DummyPackage::getFilename()
{
    return m_testPkgFilename;
}

void DummyPackage::setFilename(const std::string &fname)
{
    m_testPkgFilename = fname;
}

void DummyPackage::setMaintainer(const std::string &maint)
{
    m_maintainer = maint;
}

const std::vector<std::string> &DummyPackage::contents()
{
    return m_contents;
}

std::vector<std::uint8_t> DummyPackage::getFileData(const std::string &fname)
{
    if (fname == "TEST") {
        return {'N', 'O', 'T', 'H', 'I', 'N', 'G'};
    }
    return {};
}

void DummyPackage::finish()
{
    // No-op for dummy package
}

PackageKind DummyPackage::kind() const noexcept
{
    return m_kind;
}

void DummyPackage::setKind(PackageKind v) noexcept
{
    m_kind = v;
}

void DummyPackage::setDescription(const std::string &text, const std::string &locale)
{
    m_description[locale] = text;
}

} // namespace ASGenerator
