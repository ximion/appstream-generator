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

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <cstdint>

#include "backends/interfaces.h"

namespace ASGenerator
{

/**
 * Fake package which has the sole purpose of allowing easy injection of local
 * data that does not reside in packages.
 */
class DataInjectPackage final : public Package
{
public:
    DataInjectPackage(const std::string &pname, const std::string &parch, const std::string &prefix);

    std::string name() const override;
    std::string ver() const override;
    std::string arch() const override;
    PackageKind kind() const noexcept override;
    const std::unordered_map<std::string, std::string> &description() const override;
    std::string getFilename() override;
    std::string maintainer() const override;
    void setMaintainer(const std::string &maint);

    const std::string &dataLocation() const;
    void setDataLocation(const std::string &value);

    const std::string &archDataLocation() const;
    void setArchDataLocation(const std::string &value);

    const std::vector<std::string> &contents() override;
    std::vector<std::uint8_t> getFileData(const std::string &fname) override;
    void finish() override;

private:
    std::string m_pkgname;
    std::string m_pkgarch;
    std::string m_pkgmaintainer;
    std::unordered_map<std::string, std::string> m_desc;
    std::unordered_map<std::string, std::string> m_contents;
    std::string m_fakePrefix;
    std::string m_dataLocation;
    std::string m_archDataLocation;

    mutable std::vector<std::string> m_contentsVector;
};

} // namespace ASGenerator
