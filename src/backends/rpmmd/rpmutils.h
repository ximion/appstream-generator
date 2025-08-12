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

namespace ASGenerator
{

class Downloader;

/**
 * If URL is remote, download it, otherwise use it verbatim.
 *
 * Returns: Path to the file, which is guaranteed to exist.
 *
 * Params:
 *      url = First part of the address, i.e.
 *               "http://ftp.debian.org/debian/" or "/srv/mirrors/debian/"
 *      destLocation = If the file is remote, the directory to save it under,
 *                     which is created if necessary.
 */
std::string downloadIfNecessary(
    const std::string &url,
    const std::string &destLocation,
    Downloader *downloader = nullptr);

} // namespace ASGenerator
