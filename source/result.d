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
import std.conv : to;
import appstream.Component;
import dyaml.all;

import ag.hint;
import ag.utils : buildCptGlobalID;
import ag.backend.intf;


class GeneratorResult
{

private:
    Component[string] cpts;
    string[Component] cptGCID;
    HintList[string] hints;

public:
    string pkid;
    string pkgname;

public:

    this (Package pkg)
    {
        this.pkid = Package.getId (pkg);
        this.pkgname = pkg.name;
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

    void updateComponentGCID (Component cpt, string data)
    {
        import std.digest.md;

        auto cid = cpt.getId ();
        if (data.empty) {
            cptGCID[cpt] = buildCptGlobalID (cid, "???-NO_CHECKSUM-???");
            return;
        }

        auto hash = md5Of (data);
        auto checksum = toHexString (hash);
        cptGCID[cpt] = buildCptGlobalID (cid, to!string (checksum));
    }

    void addComponent (Component cpt, string data = "")
    {
        string cid = cpt.getId ();
        if (cid.empty)
            throw new Exception ("Can not add component without ID to results set.");

        cpt.setPkgnames ([this.pkgname]);
        cpts[cid] = cpt;
        updateComponentGCID (cpt, data);
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
     * Create YAML metadata for the hints found for the package
     * associacted with this GeneratorResult.
     */
    string hintsToYaml ()
    {
        import std.stream;

        if (hints.length == 0)
            return null;

        Node[][string] map;
        foreach (iter; hints.byKey ()) {
            auto cid = iter;
            auto hints = hints[cid];
            Node[] hintNodes;
            foreach (GeneratorHint hint; hints) {
                hintNodes ~= hint.toYamlNode ();
            }
            map[cid] = hintNodes;
        }

        auto root = Node ([pkid: map]);

        auto stream = new MemoryStream ();
        auto dumper = Dumper (stream);
        dumper.explicitStart = true;
        dumper.explicitEnd = false;
        dumper.dump(root);

        return stream.toString ();
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

    string gcidForComponent (Component cpt)
    {
        auto cgp = (cpt in cptGCID);
        if (cgp is null)
            return null;
        return *cgp;
    }

    string[] getGCIDs ()
    {
        return cptGCID.values ();
    }

}

unittest
{
    import ag.backend.debian.debpackage;
    writeln ("TEST: ", "GeneratorResult");

    auto pkg = new DebPackage ("foobar", "1.0", "amd64");
    auto res = new GeneratorResult (pkg);

    auto vars = ["rainbows": "yes", "unicorns": "no", "storage": "towel"];
    res.addHint ("just-a-unittest", "org.freedesktop.foobar.desktop", vars);
    res.addHint ("metainfo-chocolate-missing", "org.freedesktop.awesome-bar.desktop", "Nothing is good without chocolate. Add some.");
    res.addHint ("metainfo-does-not-frobnicate", "org.freedesktop.awesome-bar.desktop", "Frobnicate functionality is missing.");

    writeln (res.hintsToYaml ());
}
