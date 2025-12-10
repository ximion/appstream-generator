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
#include <filesystem>
#include <nlohmann/json.hpp>

#include "../interfaces.h"
#include "../../utils.h"
#include "fbsdpkg.h"

namespace ASGenerator
{

class FreeBSDPackageIndex : public PackageIndex
{
public:
    explicit FreeBSDPackageIndex(const std::string &dir);

    void release() override;

    std::vector<std::shared_ptr<Package>> packagesFor(
        const std::string &suite,
        const std::string &section,
        const std::string &arch,
        bool withLongDescs = true) override;

    std::shared_ptr<Package> packageForFile(
        const std::string &fname,
        const std::string &suite = "",
        const std::string &section = "") override;

    bool hasChanges(
        std::shared_ptr<DataStore> dstore,
        const std::string &suite,
        const std::string &section,
        const std::string &arch) override;

    std::string dataPrefix() const override;

private:
    fs::path m_rootDir;
    std::string m_dataPrefix;
    std::unordered_map<std::string, std::vector<std::shared_ptr<Package>>> m_pkgCache;
    std::mutex m_cacheMutex; // Thread safety for cache access

    std::vector<std::shared_ptr<Package>> loadPackages(
        const std::string &suite,
        const std::string &section,
        const std::string &arch);
};

} // namespace ASGenerator
