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

module ag.backend.debian.contentsindex;

import std.stdio;
import std.path;
import std.string;

import ag.logging;
import ag.backend.intf;
import ag.backend.debian.debpackage;


private struct PkgInfo
{
    string name;
}

class DebianContentsIndex : ContentsIndex
{

private:
    PkgInfo[string] filePkg;

public:

    this ()
    {

    }

    void loadDataFor (string dir, string suite, string section, string arch)
    {
        // TODO
    }

    Package packageForFile (string fname)
    {
        // TODO
        return null;
    }

    @property string[] files ()
    {
        // TODO
        return null;
    }

    void close ()
    {
        // TODO
    }
}
