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

module ag.result;

import std.stdio;
import std.string;
import std.array : empty;
import appstream.Component;

import ag.hint;


class GeneratorResult
{

private:
    Component[string] cpts;
    string[Component] cptGID;
    GeneratorHint[] hints;

public:

    this ()
    {
    }

    bool isIgnored ()
    {
        return cpts.length == 0;
    }

    Component getComponent (string id)
    {
        auto ptr = (id in cpts);
        if (ptr is null)
            return null;
        return *ptr;
    }

    void addComponent (Component cpt)
    {
        string cid = cpt.getId ();
        if (cid.empty)
            throw new Exception ("Can not add component without ID to results set.");

        cpts[cid] = cpt;
    }

    void addHint (string tag, string msg)
    {
        auto hint = new GeneratorHint (tag);
        hints ~= hint;
    }
}
