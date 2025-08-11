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
#include <filesystem>
#include <libxml/tree.h>

#include "../interfaces.h"
#include "rpmpkg.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

class RPMPackageIndex : public PackageIndex
{
public:
    explicit RPMPackageIndex(const std::string &dir);
    ~RPMPackageIndex();

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

private:
    fs::path m_rootDir;
    fs::path m_tmpRootDir;
    std::unordered_map<std::string, std::vector<std::shared_ptr<Package>>> m_pkgCache;
    mutable std::mutex m_cacheMutex; // Thread safety for cache access

    void setPkgDescription(std::shared_ptr<RPMPackage> pkg, const std::string &pkgDesc);
    std::vector<std::shared_ptr<RPMPackage>> loadPackages(
        const std::string &suite,
        const std::string &section,
        const std::string &arch);
};

} // namespace ASGenerator
