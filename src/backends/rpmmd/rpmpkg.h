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
#include <memory>
#include <mutex>

#include "../interfaces.h"
#include "../../utils.h"

namespace ASGenerator
{

class ArchiveDecompressor;

class RPMPackage : public Package
{
public:
    RPMPackage();
    ~RPMPackage() override = default;

    std::string name() const override;
    void setName(const std::string &val);

    std::string ver() const override;
    void setVersion(const std::string &val);

    std::string arch() const override;
    void setArch(const std::string &val);

    const std::unordered_map<std::string, std::string> &description() const override;
    const std::unordered_map<std::string, std::string> &summary() const override;

    std::string getFilename() override;
    void setFilename(const std::string &fname);

    std::string maintainer() const override;
    void setMaintainer(const std::string &maint);

    void setDescription(const std::string &text, const std::string &locale);
    void setSummary(const std::string &text, const std::string &locale);

    std::vector<std::uint8_t> getFileData(const std::string &fname) override;

    const std::vector<std::string> &contents() override;
    void setContents(const std::vector<std::string> &c);

    void finish() override;

private:
    std::string m_pkgname;
    std::string m_pkgver;
    std::string m_pkgarch;
    std::string m_pkgmaintainer;
    std::unordered_map<std::string, std::string> m_desc;
    std::unordered_map<std::string, std::string> m_summ;
    std::string m_pkgFname;
    fs::path m_localPkgFname;

    std::vector<std::string> m_contentsL;
    std::unique_ptr<ArchiveDecompressor> m_archive;

    mutable std::mutex m_mutex;
};

} // namespace ASGenerator
