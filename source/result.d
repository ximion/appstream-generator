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

import std.stdio;
import std.string;
import std.array : empty;
import std.conv : to;
import std.json;
import appstream.Component;

import hint;
import utils : buildCptGlobalID;
import backends.interfaces;


class GeneratorResult
{

private:
    Component[string] cpts;
    string[Component] cptGCID;
    string[string] mdataHashes;
    HintList[string] hints;

public:
    immutable string pkid;
    immutable string pkgname;
    Package pkg;

public:

    this (Package pkg)
    {
        this.pkid = pkg.id;
        this.pkgname = pkg.name;
        this.pkg = pkg;
    }

    @safe
    bool packageIsIgnored () pure
    {
        return (cpts.length == 0) && (hints.length == 0);
    }

    @safe
    Component getComponent (string id) pure
    {
        auto ptr = (id in cpts);
        if (ptr is null)
            return null;
        return *ptr;
    }

    @trusted
    Component[] getComponents () pure
    {
        return cpts.values ();
    }

    @trusted
    bool isIgnored (Component cpt)
    {
        return getComponent (cpt.getId ()) is null;
    }

    @trusted
    void updateComponentGCID (Component cpt, string data)
    {
        import std.digest.md;

        auto cid = cpt.getId ();
        if (data.empty) {
            cptGCID[cpt] = buildCptGlobalID (cid, "???-NO_CHECKSUM-???");
            return;
        }

        auto oldHashP = (cid in mdataHashes);
        string oldHash = "";
        if (oldHashP !is null)
            oldHash = *oldHashP;

        auto hash = md5Of (oldHash ~ data);
        auto checksum = toHexString (hash);
        auto newHash = to!string (checksum);

        mdataHashes[cid] = newHash;
        cptGCID[cpt] = buildCptGlobalID (cid, newHash);
    }

    @trusted
    void addComponent (Component cpt, string data = "")
    {
        string cid = cpt.getId ();
        if (cid.empty)
            throw new Exception ("Can not add component without ID to results set.");

        cpt.setPkgnames ([this.pkgname]);
        cpts[cid] = cpt;
        updateComponentGCID (cpt, data);
    }

    @safe
    void dropComponent (string cid) pure
    {
        auto cpt = getComponent (cid);
        if (cpt is null)
            return;
        cpts.remove (cid);
        cptGCID.remove (cpt);
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      id = The component-id or component itself this tag is assigned to.
     *      tag    = The hint tag.
     *      params = Dictionary of parameters to insert into the issue report.
     **/
    @trusted
    void addHint (T) (T id, string tag, string[string] params)
        if (is(T == string) || is(T == Component) || is(T == typeof(null)))
    {
        static if (is(T == string)) {
            immutable cid = id;
        } else {
            static if (is(T == typeof(null)))
                immutable cid = "general";
            else
                immutable cid = id.getId ();
        }

        auto hint = new GeneratorHint (tag, cid);
        hint.setVars (params);
        hints[cid] ~= hint;

        // we stop dealing with this component when we encounter a fatal
        // error.
        if (hint.isError ())
            dropComponent (cid);
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      id = The component-id or component itself this tag is assigned to.
     *      tag = The hint tag.
     *      msg = An error message to add to the report.
     **/
    @safe
    void addHint (T) (T id, string tag, string msg = null)
    {
        string[string] vars;
        if (msg !is null)
            vars = ["msg": msg];
        addHint (id, tag, vars);
    }

    /**
     * Create JSON metadata for the hints found for the package
     * associacted with this GeneratorResult.
     */
    string hintsToJson ()
    {
        import std.stream;

        if (hints.length == 0)
            return null;

        // is this really the only way you can set a type for JSONValue?
        auto map = JSONValue (["null": 0]);
        map.object.remove ("null");

        foreach (cid; hints.byKey ()) {
            auto cptHints = hints[cid];
            auto hintNodes = JSONValue ([0, 0]);
            hintNodes.array = [];
            foreach (GeneratorHint hint; cptHints) {
                hintNodes.array ~= hint.toJsonNode ();
            }

            map.object[cid] = hintNodes;
        }

        auto root = JSONValue (["package": JSONValue (pkid), "hints": map]);
        return toJSON (&root, true);
    }

    /**
     * Drop invalid components and components with errors.
     */
    void finalize ()
    {
        // we need to duplicate the associative array, because the addHint() function
        // may remove entries from "cpts", breaking our foreach loop.
        foreach (cpt; cpts.dup.byValue ()) {
            auto ckind = cpt.getKind ();
            if (ckind == ComponentKind.DESKTOP_APP) {
                // checks specific for .desktop and web apps
                if (cpt.getIcons ().len == 0)
                    addHint (cpt.getId (), "gui-app-without-icon");
            }
            if (ckind == ComponentKind.UNKNOWN)
                addHint (cpt.getId (), "metainfo-unknown-type");

            if ((!cpt.hasBundle ()) && (cpt.getPkgnames ().empty))
                addHint (cpt.getId (), "no-install-candidate");

            cpt.setActiveLocale ("C");
            if (cpt.getName ().empty)
                addHint (cpt.getId (), "metainfo-no-name");
            if (cpt.getSummary ().empty)
                addHint (cpt.getId (), "metainfo-no-summary");
        }

        // inject package descriptions, if needed
        foreach (cpt; cpts.byValue ()) {
            if (cpt.getKind () == ComponentKind.DESKTOP_APP) {
                auto flags = cpt.getValueFlags;
                cpt.setValueFlags (flags | AsValueFlags.NO_TRANSLATION_FALLBACK);
                scope (exit) cpt.setActiveLocale ("C");

                bool desc_from_pkg_hint_added = false;
                foreach (ref lang, ref desc; pkg.description) {
                    cpt.setActiveLocale (lang);

                    if (cpt.getDescription ().empty) {
                        cpt.setDescription (desc, lang);
                        if (!desc_from_pkg_hint_added) {
                            addHint (cpt, "description-from-package", ["locale": lang]);
                            desc_from_pkg_hint_added = true;
                        }
                    }
                }
            }
        }
    }

    /**
     * Return the number of components we've found.
     **/
    @safe
    ulong componentsCount () pure
    {
        return cpts.length;
    }

    /**
     * Return the number of hints that have been emitted.
     **/
    @safe
    ulong hintsCount () pure
    {
        return hints.length;
    }

    @safe
    string gcidForComponent (Component cpt) pure
    {
        auto cgp = (cpt in cptGCID);
        if (cgp is null)
            return null;
        return *cgp;
    }

    @trusted
    string[] getGCIDs () pure
    {
        return cptGCID.values ();
    }

}

unittest
{
    import backends.dummy.dummypkg;
    writeln ("TEST: ", "GeneratorResult");

    auto pkg = new DummyPackage ("foobar", "1.0", "amd64");
    auto res = new GeneratorResult (pkg);

    auto vars = ["rainbows": "yes", "unicorns": "no", "storage": "towel"];
    res.addHint ("org.freedesktop.foobar.desktop", "just-a-unittest", vars);
    res.addHint ("org.freedesktop.awesome-bar.desktop", "metainfo-chocolate-missing", "Nothing is good without chocolate. Add some.");
    res.addHint ("org.freedesktop.awesome-bar.desktop", "metainfo-does-not-frobnicate", "Frobnicate functionality is missing.");

    writeln (res.hintsToJson ());
}
