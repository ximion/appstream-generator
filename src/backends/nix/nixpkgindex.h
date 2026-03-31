/*
 * Copyright (C) 2026 Victor Fuentes <vlinkz@snowflakeos.org>
 *
 * Based on the archlinux, alpinelinux, and freebsd backends, which are:
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) 2020-2025 Rasmus Thomsen <oss@cogitri.dev>
 * Copyright (C) 2023-2025 Serenity Cyber Security, LLC. Author: Gleb Popov <arrowd@FreeBSD.org>
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

#include "../interfaces.h"
#include "../../utils.h"
#include "nixpkg.h"

namespace ASGenerator
{

class NixPackageIndex : public PackageIndex
{
public:
    explicit NixPackageIndex(const std::string &storeUrl);

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
    std::string m_storeUrl;
    std::string m_nixExe;
    std::unordered_map<std::string, std::vector<std::shared_ptr<Package>>> m_pkgCache;
    std::mutex m_cacheMutex;

    std::vector<std::shared_ptr<Package>> loadPackages(
        const std::string &suite,
        const std::string &section,
        const std::string &arch);
};

} // namespace ASGenerator
