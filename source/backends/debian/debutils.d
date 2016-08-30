/*
 * Copyright (C) 2016 Canonical Ltd
 * Author(s): Iain Lane <iain@orangesquash.org.uk>
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

module backends.debian.debutils;

import std.string;
static import std.file;

import logging;
import utils : downloadFile, isRemote;

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
immutable (string) downloadIfNecessary (const string prefix,
                                        const string destPrefix,
                                        const string suffix)
{
    import std.net.curl;
    import std.path;

    immutable exts = ["xz", "bz2", "gz"];
    foreach (ref ext; exts) {
        immutable fileName = format (buildPath (prefix, suffix), ext);
        immutable destFileName = format (buildPath (destPrefix, suffix), ext);

        if (fileName.isRemote) {
            try {
                /* This should use download(), but that doesn't throw errors */
                downloadFile (fileName, destFileName);

                return destFileName;
            } catch (CurlException ex) {
                logDebug ("Could not download: %s", ex.msg);
            }
        } else {
            if (std.file.exists (fileName))
                return fileName;
        }
    }

    /* all extensions failed, so we failed */
    throw new Exception (format ("Could not obtain any file matching %s",
                         buildPath (prefix, suffix)));
}
