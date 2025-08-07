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

#include "../interfaces.h"
#include "dummypkg.h"

namespace ASGenerator
{

class DummyPackageIndex : public PackageIndex
{
private:
    std::unordered_map<std::string, std::vector<std::unique_ptr<Package>>> m_pkgCache;

public:
    DummyPackageIndex(const std::string &dir);

    void release() override;

    std::vector<std::unique_ptr<Package>> packagesFor(
        const std::string &suite,
        const std::string &section,
        const std::string &arch,
        bool withLongDescs = true) override;

    std::unique_ptr<Package> packageForFile(
        const std::string &fname,
        const std::string &suite = "",
        const std::string &section = "") override;

    bool hasChanges(DataStore *dstore, const std::string &suite, const std::string &section, const std::string &arch)
        override;
};

} // namespace ASGenerator
