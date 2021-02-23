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
 * Helper function for GeneratorResult.finalize()
 */
extern(C)
int evaluateCustomEntry (void *keyPtr, void *value, void *userData)
{
    auto key = (cast(const(char)*) keyPtr).fromStringz;
    auto conf = *cast(Config*) userData;

    if (key in conf.allowedCustomKeys)
        return false; // FALSE, do not delete

    // remove invalid key
    return true;
}

/**
 * Holds metadata generator result(s) and issue hints
 * for a single package.
 */
final class GeneratorResult : Result
{

public:
    Package pkg;

    this (Package pkg)
    {
        super();
        setBundleKind (BundleKind.PACKAGE);
        setBundleId (pkg.name);
        this.pkg = pkg;
    }

    @property
    string pkid ()
    {
        return pkg.id;
    }

    @trusted
    bool isIgnored (Component cpt)
    {
        return getComponent (cpt.getId) is null;
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

    /**
     * Drop invalid components and components with errors.
     */
    void finalize ()
    {
        auto conf = Config.get ();

        // the fetchComponents() method creates a new PtrArray with references to the #AsComponent instances.
        // so we are free to call addHint & Co. which may remove components from the pool.
        auto cptsPtrArray = fetchComponents ();
        for (uint i = 0; i < cptsPtrArray.len; i++) {
            auto cpt = new Component (cast (AsComponent*) cptsPtrArray.index (i));
            immutable ckind = cpt.getKind;
            cpt.setActiveLocale ("C");

            if (ckind == ComponentKind.UNKNOWN)
                if (!addHint (cpt, "metainfo-unknown-type"))
                    continue;

            if (cpt.getMergeKind == MergeKind.NONE) {
                // only perform these checks if we don't have a merge-component
                // (which is by definition incomplete and only is required to have its ID present)

                if (cpt.getPkgnames.empty) {
                    // no packages are associated with this component

                    if (ckind != ComponentKind.WEB_APP &&
                        ckind != ComponentKind.OPERATING_SYSTEM &&
                        ckind != ComponentKind.REPOSITORY) {
                            // this component is not allowed to have no installation candidate
                            if (!cpt.hasBundle) {
                                if (!addHint (cpt, "no-install-candidate"))
                                    continue;
                            }
                    }
                } else {
                    // packages are associated with this component

                    if (pkg.kind == PackageKind.FAKE) {
                        import std.algorithm : canFind;
                        import asgen.config : EXTRA_METAINFO_FAKE_PKGNAME;

                        if (cpt.getPkgnames.canFind (EXTRA_METAINFO_FAKE_PKGNAME)) {
                            if (!addHint (cpt, "component-fake-package-association"))
                                continue;
                        }
                    }

                    // strip out any release artifact information of components that have a
                    // distribution package association
                    if (!conf.feature.propagateMetaInfoArtifacts) {
                        import appstream.c.functions : as_release_get_artifacts;
                        import glib.c.functions : g_ptr_array_set_size;

                        auto relArr = cpt.getReleases;
                        for (uint j = 0; j < relArr.len; j++) {
                            auto releasePtr = cast (AsRelease*) relArr.index (j);
                            g_ptr_array_set_size (as_release_get_artifacts (releasePtr), 0);
                        }
                    }
                }

                if (cpt.getName.empty)
                    if (!addHint (cpt, "metainfo-no-name"))
                        continue;

                if (cpt.getSummary.empty)
                    if (!addHint (cpt, "metainfo-no-summary"))
                        continue;

                // ensure that everything that should have an icon has one
                if (cpt.getIcons.len == 0) {
                    if (ckind == ComponentKind.DESKTOP_APP) {
                        if (!addHint (cpt, "gui-app-without-icon"))
                            continue;
                    } else if (ckind == ComponentKind.WEB_APP) {
                        if (!addHint (cpt, "web-app-without-icon"))
                            continue;
                    } else if (ckind == ComponentKind.FONT) {
                        if (!addHint (cpt, "font-without-icon"))
                            continue;
                    } else if (ckind == ComponentKind.OPERATING_SYSTEM) {
                        if (!addHint (cpt, "os-without-icon"))
                            continue;
                    }
                }

                // desktop and web apps get extra treatment (more validation, addition of fallback long-description)
                if (ckind == ComponentKind.DESKTOP_APP || ckind == ComponentKind.WEB_APP) {
                    // desktop-application components are required to have a category
                    if (cpt.getCategories.len <= 0)
                        if (!addHint (cpt, "no-valid-category"))
                            continue;

                    // inject package descriptions, if needed
                    auto flags = cpt.getValueFlags;
                    cpt.setValueFlags (flags | AsValueFlags.NO_TRANSLATION_FALLBACK);

                    cpt.setActiveLocale ("C");
                    if (cpt.getDescription.empty) {
                        // component doesn't have a long description, add one from
                        // the packaging.
                        auto desc_added = false;
                        foreach (ref lang, ref desc; pkg.description) {
                                cpt.setDescription (desc, lang);
                                desc_added = true;
                        }

                        if (conf.feature.warnNoMetaInfo) {
                            if (!addHint (cpt, "no-metainfo"))
                                continue;
                        }

                        if (desc_added) {
                            if (!conf.feature.warnNoMetaInfo) {
                                if (!addHint (cpt, "description-from-package"))
                                    continue;
                            }
                        } else {
                            if ((ckind == ComponentKind.DESKTOP_APP) ||
                                (ckind == ComponentKind.CONSOLE_APP) ||
                                (ckind == ComponentKind.WEB_APP)) {
                                    if (!addHint (cpt, "description-missing", ["kind": AsUtils.componentKindToString (ckind)]))
                                    continue;
                            }
                        }
                    }

                    // check if we can add a launchable here
                    if (ckind == ComponentKind.DESKTOP_APP) {
                        if ((cpt.getLaunchable (LaunchableKind.DESKTOP_ID) is null) && (cpt.getId.endsWith (".desktop"))) {
                            import appstream.Launchable : Launchable, LaunchableKind;
                            auto launch = new Launchable;
                            launch.setKind (LaunchableKind.DESKTOP_ID);
                            launch.addEntry (cpt.getId);
                            cpt.addLaunchable (launch);
                        }
                    }
                } // end of checks for desktop/web apps

            } // end of check for non-merge components

            // finally, filter custom tags
            auto customHashTable = cpt.getCustom ();
            immutable noCustomKeysAllowed = conf.allowedCustomKeys.length == 0;
            if (customHashTable.size > 0) {
                if (noCustomKeysAllowed) {
                    // if we don't allow any custom keys, we can delete them faster
                    customHashTable.removeAll ();
                    continue;
                }

                // filter the custom values
                customHashTable.foreachRemove (&evaluateCustomEntry, &conf);
            }

        } // end of components loop
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
