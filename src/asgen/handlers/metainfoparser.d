/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.handlers.metainfoparser;

import std.path : baseName;
import std.uni : toLower;
import std.string : format;
import std.array : empty;
import std.stdio;
import appstream.Metadata;
import appstream.Component;

import asgen.result;
import asgen.utils;


private bool isMetainfoLicense (string license) pure
{
    import asgen.bindings.appstream_utils;
    import std.string : toStringz;
    return as_license_is_metadata_license (license.toStringz);
}

Component parseMetaInfoFile (Metadata mdata, GeneratorResult gres, const string data, const string mfname)
{
    try {
        mdata.parse (data, FormatKind.XML);
    } catch (Exception e) {
        gres.addHint ("general", "metainfo-parsing-error", e.msg);
        return null;
    }

    auto cpt = mdata.getComponent ();
    if (cpt is null)
        return null;

    // check if we have a component-id, a component without ID is invalid
    if (cpt.getId.empty) {
        gres.addHint (null, "metainfo-no-id", ["fname": mfname]);
        return null;
    }
    gres.addComponent (cpt);

    // check if we can actually legally use this metadata
    if (!isMetainfoLicense (cpt.getMetadataLicense())) {
        gres.addHint (cpt, "metainfo-license-invalid", ["license": cpt.getMetadataLicense()]);
        return null;
    }

    // quit immediately if we have an unknown component type
    if (cpt.getKind () == ComponentKind.UNKNOWN) {
        gres.addHint (cpt, "metainfo-unknown-type");
        return null;
    }

    return cpt;
}

Component parseMetaInfoFile (GeneratorResult gres, const string data, const string mfname)
{
    auto mdata = new Metadata ();
    mdata.setLocale ("ALL");
    mdata.setFormatStyle (FormatStyle.METAINFO);

    return parseMetaInfoFile (mdata, gres, data, mfname);
}
