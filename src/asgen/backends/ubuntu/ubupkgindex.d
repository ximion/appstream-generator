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

module asgen.backends.ubuntu.ubupkgindex;

import std.array : appender;
import std.conv : to;

import asgen.backends.debian;
import asgen.backends.interfaces;
import asgen.backends.ubuntu.ubupkg;

final class UbuntuPackageIndex : DebianPackageIndex
{

private:
    LanguagePackProvider langpacks;

public:
    this (string dir)
    {
        super (dir);

        /*
         * UbuntuPackage needs to extract the langpacks, so we give it an array
         * of langpacks. There is a small overhead when computing this array
         * which might be unnecessary if no processed packages are using
         * langpacks, but otherwise we need to keep a reference to all packages
         * around, which is very expensive.
         */
        langpacks = new LanguagePackProvider (tmpDir);
    }

    override protected
    DebPackage newPackage (string name, string ver, string arch)
    {
        return new UbuntuPackage (name, ver, arch, langpacks);
    }

    override
    Package[] packagesFor (string suite, string section, string arch, bool withLongDescs = true)
    {
        import std.string : startsWith;

        auto pkgs = super.packagesFor (suite, section, arch, withLongDescs);
        auto pkgslangpacks = appender!(UbuntuPackage[]);
        pkgslangpacks.reserve (32);

        foreach (ref pkg; pkgs) {
                if (pkg.name.startsWith ("language-pack-"))
                    pkgslangpacks ~= pkg.to!UbuntuPackage;
        }

        langpacks.addLanguagePacks (pkgslangpacks.data);

        return pkgs;
    }

    override
    Package packageForFile (string fname, string suite = null, string section = null)
    {
        return null; // FIXME: not implemented
    }
}
