/*
 * Copyright (C) 2016-2023 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.backends.rpmmd.rpmutils;

import std.string : format;
import std.path : buildPath, baseName;
static import std.file;

import asgen.logging;
import asgen.downloader : Downloader, DownloadException;
import asgen.utils : isRemote;

/**
 * If URL is remote, download it, otherwise use it verbatim.
 *
 * Returns: Path to the file, which is guaranteed to exist.
 *
 * Params:
 *      url = First part of the address, i.e.
 *               "http://ftp.debian.org/debian/" or "/srv/mirrors/debian/"
 *      destPrefix = If the file is remote, the directory to save it under,
 *                   which is created if necessary.
 */
immutable(string) downloadIfNecessary (const string url,
        const string destLocation,
        Downloader downloader = null)
{
    import std.path : buildPath;

    if (downloader is null)
        downloader = Downloader.get;

    if (url.isRemote) {
        immutable destFileName = buildPath(destLocation, url.baseName);
        try {
            downloader.downloadFile(url, destFileName);
            return destFileName;
        } catch (DownloadException e) {
            logDebug("Unable to download: %s", e.msg);
        }
    } else {
        if (std.file.exists(url))
            return url;
    }

    throw new Exception("Could not obtain any file %s".format(url));
}
