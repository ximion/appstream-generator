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

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <cstdint>

#include "../interfaces.h"

namespace ASGenerator
{

class DummyPackage : public Package
{
private:
    std::string m_name;
    std::string m_version;
    std::string m_arch;
    std::string m_maintainer;
    std::unordered_map<std::string, std::string> m_description;
    std::string m_testPkgFilename;
    PackageKind m_kind;
    std::vector<std::string> m_contents;

public:
    DummyPackage(const std::string &pname, const std::string &pver, const std::string &parch);

    std::string name() const override;
    std::string ver() const override;
    std::string arch() const override;
    std::string maintainer() const override;

    const std::unordered_map<std::string, std::string> &description() const override;

    std::string getFilename() override;
    void setFilename(const std::string &fname);

    void setMaintainer(const std::string &maint);

    const std::vector<std::string> &contents() override;

    std::vector<std::uint8_t> getFileData(const std::string &fname) override;

    void finish() override;

    PackageKind kind() const noexcept override;
    void setKind(PackageKind v) noexcept;

    void setDescription(const std::string &text, const std::string &locale);
};

} // namespace ASGenerator
