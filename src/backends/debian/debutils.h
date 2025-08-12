/*
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) The APT development team.
 * Copyright (C) 2016 Canonical Ltd
 *   Author(s): Iain Lane <iain@orangesquash.org.uk>
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

namespace ASGenerator
{

class Downloader;

/**
 * If prefix is remote, download the first of (prefix + suffix).{xz,bz2,gz},
 * otherwise check if any of (prefix + suffix).{xz,bz2,gz} exists.
 *
 * Returns: Path to the file, which is guaranteed to exist.
 *
 * Params:
 *      prefix = First part of the address, i.e.
 *               "http://ftp.debian.org/debian/" or "/srv/mirrors/debian/"
 *      destPrefix = If the file is remote, the directory to save it under,
 *                   which is created if necessary.
 *      suffix = the rest of the address, so that (prefix +
 *               suffix).format({xz,bz2,gz}) is a full path or URL, i.e.
 *               "dists/unstable/main/binary-i386/Packages.%s". The suffix must
 *               contain exactly one "%s"; this function is only suitable for
 *               finding `.xz`, `.bz2` and `.gz` files.
 */
std::string downloadIfNecessary(
    const std::string &prefix,
    const std::string &destPrefix,
    const std::string &suffix,
    Downloader *downloader = nullptr);

/**
 * Compare two Debian-style version numbers.
 */
int compareVersions(const std::string &a, const std::string &b);

} // namespace ASGenerator
