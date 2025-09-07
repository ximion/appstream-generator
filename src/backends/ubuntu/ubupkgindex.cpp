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

#include "ubupkgindex.h"

#include <format>
#include <algorithm>

#include "../../logging.h"

namespace ASGenerator
{

UbuntuPackageIndex::UbuntuPackageIndex(const std::string &dir)
    : DebianPackageIndex(dir)
{
    /*
     * UbuntuPackage needs to extract the langpacks, so we give it an array
     * of langpacks. There is a small overhead when computing this array
     * which might be unnecessary if no processed packages are using
     * langpacks, but otherwise we need to keep a reference to all packages
     * around, which is very expensive.
     */
    m_langpacks = std::make_shared<LanguagePackProvider>(m_tmpDir);
}

void UbuntuPackageIndex::release()
{
    DebianPackageIndex::release();
    m_checkedLangPacks.clear();

    // replace with fresh, empty provider
    m_langpacks = std::make_shared<LanguagePackProvider>(m_tmpDir);
}

std::shared_ptr<DebPackage> UbuntuPackageIndex::newPackage(
    const std::string &name,
    const std::string &ver,
    const std::string &arch)
{
    auto ubuntuPkg = std::make_shared<UbuntuPackage>(name, ver, arch);
    ubuntuPkg->setLanguagePackProvider(m_langpacks);
    return std::static_pointer_cast<DebPackage>(ubuntuPkg);
}

std::vector<std::shared_ptr<Package>> UbuntuPackageIndex::packagesFor(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    auto pkgs = DebianPackageIndex::packagesFor(suite, section, arch, withLongDescs);

    const std::string ssaId = std::format("{}/{}/{}", suite, section, arch);
    if (m_checkedLangPacks.contains(ssaId))
        return pkgs; // no need to scan for language packs, we already did that

    // scan for language packs and add them to the data provider
    std::vector<std::shared_ptr<UbuntuPackage>> langpackPkgs;
    langpackPkgs.reserve(32);

    for (const auto &pkg : pkgs) {
        if (pkg->name().starts_with("language-pack-")) {
            // Cast to UbuntuPackage
            auto ubuntuPkg = std::dynamic_pointer_cast<UbuntuPackage>(pkg);
            if (ubuntuPkg)
                langpackPkgs.push_back(std::move(ubuntuPkg));
        }
    }

    m_langpacks->addLanguagePacks(langpackPkgs);
    m_checkedLangPacks.insert(ssaId);

    return pkgs;
}

std::shared_ptr<Package> UbuntuPackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    // FIXME: not implemented
    return nullptr;
}

} // namespace ASGenerator
