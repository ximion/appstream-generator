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

#include "rpmutils.h"

#include <filesystem>
#include <format>

#include "../../logging.h"
#include "../../downloader.h"
#include "../../utils.h"

namespace fs = std::filesystem;

namespace ASGenerator
{

std::string downloadIfNecessary(const std::string &url, const std::string &destLocation, Downloader *downloader)
{
    if (downloader == nullptr)
        downloader = &Downloader::get();

    if (isRemote(url)) {
        const std::string destFileName = (fs::path(destLocation) / fs::path(url).filename()).string();
        try {
            fs::create_directories(destLocation);
            downloader->downloadFile(url, destFileName);
            return destFileName;
        } catch (const std::exception &e) {
            logDebug("Unable to download: {}", e.what());
            throw std::runtime_error(std::format("Could not obtain file {}", url));
        }
    } else {
        if (fs::exists(url))
            return url;
    }

    throw std::runtime_error(std::format("Could not obtain file {}", url));
}

} // namespace ASGenerator
