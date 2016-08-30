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

module handlers.metainfoparser;

import std.path : baseName;
import std.uni : toLower;
import std.string : format;
import std.stdio;
import appstream.Metadata;
import appstream.Component;

import result;
import utils;


Component parseMetaInfoFile (GeneratorResult res, string data)
{
    auto mdata = new Metadata ();
    mdata.setLocale ("ALL");
    mdata.setFormatStyle (FormatStyle.METAINFO);

    try {
        mdata.parse (data, FormatKind.XML);
    } catch (Exception e) {
        res.addHint ("general", "metainfo-parsing-error", e.msg);
        return null;
    }

    auto cpt = mdata.getComponent ();
    if (cpt is null)
        return null;
    res.addComponent (cpt);

    return cpt;
}
