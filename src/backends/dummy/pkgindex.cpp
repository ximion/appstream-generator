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

#include "pkgindex.h"

#include "../../logging.h"

namespace ASGenerator
{

DummyPackageIndex::DummyPackageIndex(const std::string &dir)
{
    // Constructor doesn't need to do anything for dummy backend
}

void DummyPackageIndex::release()
{
    m_pkgCache.clear();
}

std::vector<std::unique_ptr<Package>> DummyPackageIndex::packagesFor(
    const std::string &suite,
    const std::string &section,
    const std::string &arch,
    bool withLongDescs)
{
    std::vector<std::unique_ptr<Package>> packages;
    packages.push_back(std::make_unique<DummyPackage>("test", "1.0", "amd64"));
    return packages;
}

std::unique_ptr<Package> DummyPackageIndex::packageForFile(
    const std::string &fname,
    const std::string &suite,
    const std::string &section)
{
    // FIXME: not implemented
    return nullptr;
}

bool DummyPackageIndex::hasChanges(
    DataStore *dstore,
    const std::string &suite,
    const std::string &section,
    const std::string &arch)
{
    return true;
}

} // namespace ASGenerator
