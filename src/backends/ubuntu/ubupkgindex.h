/*
 * Copyright (C) 2016-2020 Canonical Ltd
 * Author: Iain Lane <iain.lane@canonical.com>
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
#include <unordered_set>
#include <memory>

#include "../debian/debpkgindex.h"
#include "ubupkg.h"

namespace ASGenerator
{

class UbuntuPackageIndex : public DebianPackageIndex
{
public:
    explicit UbuntuPackageIndex(const std::string &dir);

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

protected:
    // Make tmpDir accessible to this class
    using DebianPackageIndex::m_tmpDir;

    std::shared_ptr<DebPackage> newPackage(const std::string &name, const std::string &ver, const std::string &arch)
        override;

private:
    std::shared_ptr<LanguagePackProvider> m_langpacks;

    // holds the IDs of suite/section/arch combinations where we scanned language packs
    std::unordered_set<std::string> m_checkedLangPacks;
};

} // namespace ASGenerator
