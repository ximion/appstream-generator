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

module ag.backend.debian.utils;

import std.string;

import ag.logging;
import ag.utils : downloadFile, isRemote;

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
                logDebug ("Couldn't download: %s", ex.msg);
            }
        } else {
            if (std.file.exists (fileName))
                return fileName;
        }
    }

    /* all extensions failed, so we failed */
    throw new Exception (format ("Couldn't obtain any file matching %s",
                         buildPath (prefix, suffix)));
}
