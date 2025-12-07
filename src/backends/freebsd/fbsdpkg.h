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

#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <cstdint>
#include <nlohmann/json.hpp>

#include "../interfaces.h"
#include "../../utils.h"

namespace ASGenerator
{

class ArchiveDecompressor;

class FreeBSDPackage : public Package
{
public:
    FreeBSDPackage(const std::string &pkgRoot, const nlohmann::json &j);
    ~FreeBSDPackage() override = default;

    std::string name() const override;
    std::string ver() const override;
    std::string arch() const override;
    std::string maintainer() const override;
    std::string getFilename() override;

    const std::unordered_map<std::string, std::string> &summary() const override;
    const std::unordered_map<std::string, std::string> &description() const override;

    std::vector<std::uint8_t> getFileData(const std::string &fname) override;

    const std::vector<std::string> &contents() override;

    void finish() override;

    PackageKind kind() const noexcept override;

private:
    nlohmann::json m_pkgjson;
    fs::path m_pkgFname;
    PackageKind m_kind;
    std::unique_ptr<ArchiveDecompressor> m_pkgArchive;
    std::vector<std::string> m_contentsL;

    // Mutable cache members for lazy initialization of summary/description
    mutable std::unordered_map<std::string, std::string> m_summaryCache;
    mutable std::unordered_map<std::string, std::string> m_descriptionCache;

    mutable std::mutex m_mutex;
};

} // namespace ASGenerator
