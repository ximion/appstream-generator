/*
 * Copyright (C) 2016 Canonical Ltd
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

module backends.ubuntu.ubupkgindex;

import backends.debian;
import backends.interfaces;
import backends.ubuntu.ubupkg;

import std.container : Array, make;

class UbuntuPackageIndex : DebianPackageIndex
{

public:
    this (string dir)
    {
        /*
         * UbuntuPackage needs to extract the langpacks, so we give it an array
         * of all packages. We don't do this here, as you migh think makes
         * sense, because it is a very expensive operation and we want to avoid
         * doing it if it's not necessary (when no packages being processed are
         * using langpacks).
         */
        allPackages = make!(Array!Package);
        super (dir);
    }

    override DebPackage newPackage (string name, string ver, string arch)
    {
        return new UbuntuPackage (name, ver, arch, tmpDir, allPackages);
    }

    override Package[] packagesFor (string suite, string section, string arch)
    {
        auto pkgs = super.packagesFor (suite, section, arch);

        allPackages ~= pkgs;

        return pkgs;
    }
}

private:
    Array!Package allPackages;
