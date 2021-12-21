/*
 * Copyright (C) 2016-2021 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.result;

import std.stdio;
import std.string : format, fromStringz, toStringz;
import std.array : empty;
import std.conv : to;
import std.algorithm : endsWith;
import std.json;
import appstream.Component;
import appstream.c.types : BundleKind;
import ascompose.Hint : Hint;
import ascompose.Result : Result;
import ascompose.c.types : AscHint;
static import appstream.Utils;
alias AsUtils = appstream.Utils.Utils;

import asgen.hintregistry;
import asgen.utils : buildCptGlobalID;
import asgen.backends.interfaces;
import asgen.config : Config;


/**
 * Helper structure to tie a package instance and compose result together.
 */
struct GeneratorResult
{
    Package pkg;
    Result res;
    alias res this;

    this (Package pkg)
    {
        res = new Result;
        res.setBundleKind (BundleKind.PACKAGE);
        res.setBundleId (pkg.name);
        this.pkg = pkg;
    }

    this (Result result, Package pkg)
    {
        this.res = result;
        this.res.setBundleKind (BundleKind.PACKAGE);
        this.res.setBundleId (pkg.name);
        this.pkg = pkg;
    }

    @property
    string pkid ()
    {
        return pkg.id;
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      id = The component-id or component itself this tag is assigned to.
     *      tag    = The hint tag.
     *      params = Dictionary of parameters to insert into the issue report.
     * Returns:
     *      True if the hint did not cause the removal of the component, False otherwise.
     **/
    @trusted
    bool addHint (T) (T id, string tag, string[string] params)
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

        string[] paramsFlat;
        foreach (const ref varName, ref varValue; params)
            paramsFlat ~= [varName, varValue];

        return addHintByCid (cid, tag, paramsFlat);
    }

    /**
     * Add an issue hint to this result.
     * Params:
     *      id = The component-id or component itself this tag is assigned to.
     *      tag = The hint tag.
     *      msg = An error message to add to the report.
     * Returns:
     *      True if the hint did not cause the removal of the component, False otherwise.
     **/
    @safe
    bool addHint (T) (T id, string tag, string msg = null)
    {
        string[string] vars;
        if (msg !is null)
            vars = ["msg": msg];
        return addHint (id, tag, vars);
    }

    /**
     * Create JSON metadata for the hints found for the package
     * associacted with this GeneratorResult.
     */
    string hintsToJson ()
    {
        if (hintsCount () == 0)
            return null;

        // FIXME: is this really the only way you can set a type for JSONValue?
        auto map = JSONValue (["null": 0]);
        map.object.remove ("null");

        foreach (ref cid; getComponentIdsWithHints ()) {
            auto cptHints = getHints (cid);
            auto hintNodes = JSONValue ([0, 0]);
            hintNodes.array = [];

            for (uint i = 0; i < cptHints.len; i++) {
                auto hint = new Hint (cast (AscHint*) cptHints.index (i));
                hintNodes.array ~= hint.toJsonValue;
            }
            map.object[cid] = hintNodes;
        }

        auto root = JSONValue (["package": JSONValue (pkid), "hints": map]);
        return root.toJSON (true);
    }
}

unittest
{
    import asgen.backends.dummy.dummypkg;
    writeln ("TEST: ", "GeneratorResult");
    loadHintsRegistry ();

    auto pkg = new DummyPackage ("foobar", "1.0", "amd64");
    auto res = new GeneratorResult (pkg);

    auto vars = ["rainbows": "yes", "unicorns": "no", "storage": "towel"];
    res.addHint ("org.freedesktop.foobar.desktop", "desktop-file-hidden-set", vars);
    res.addHint ("org.freedesktop.awesome-bar.desktop", "metainfo-validation-error", "Nothing is good without chocolate. Add some.");
    res.addHint ("org.freedesktop.awesome-bar.desktop", "screenshot-video-check-failed", "Frobnicate functionality is missing.");

    writeln (res.hintsToJson ());
}
