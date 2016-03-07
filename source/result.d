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
    HintList[string] hints;

public:
    string pkid;

public:

    this (string pkid)
    {
        this.pkid = pkid;
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

    Component[] getComponents ()
    {
        return cpts.values ();
    }

    void addComponent (Component cpt)
    {
        string cid = cpt.getId ();
        if (cid.empty)
            throw new Exception ("Can not add component without ID to results set.");

        cpts[cid] = cpt;
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      tag    = The hint tag.
     *      cid    = The component-id this tag is assigned to.
     *      params = Dictionary of parameters to insert into the issue report.
     **/
    void addHint (string tag, string cid, string[string] params)
    {
        auto hint = new GeneratorHint (tag, cid);
        hint.setVars (params);
        if (cid is null)
            cid = "general";
        hints[cid] ~= hint;
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      tag = The hint tag.
     *      cid = The component-id this tag is assigned to.
     *      msg = An error message to add to the report.
     **/
    void addHint (string tag, string cid, string msg)
    {
        string[string] vars = ["msg": msg];
        addHint (tag, cid, vars);
    }

    /**
     * Drop invalid components and components with errors.
     */
    void finalize ()
    {
        // TODO
    }

    /**
     * Return the number of components we've found.
     **/
    ulong componentsCount ()
    {
        return cpts.length;
    }

    /**
     * Return the number of hints that have been emitted.
     **/
    ulong hintsCount ()
    {
        return hints.length;
    }

}
