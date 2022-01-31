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

module asgen.extractor;

import std.array : appender;
import std.stdio;
import std.string;
import std.path : baseName;
import std.algorithm : canFind;
import std.typecons : scoped;
import appstream.Component;
import appstream.Metadata;
import ascompose.Hint : Hint;
import ascompose.Compose : Compose, IconPolicy;
import ascompose.Unit : Unit;
import ascompose.c.types : ComposeFlags, AscResult, AscUnit;
import glib.Bytes : Bytes;
import glib.c.types : GPtrArray;

import asgen.config : Config, DataType;
import asgen.logging;
import asgen.hintregistry;
import asgen.result;
import asgen.backends.interfaces;
import asgen.datastore;
import asgen.iconhandler : IconHandler;
import asgen.utils : componentGetRawIcon, toStaticGBytes;
import asgen.packageunit : PackageUnit;
import asgen.localeunit : LocaleUnit;


final class DataExtractor
{

private:
    Compose compose;

    package DataType dtype;
    package DataStore dstore;
    package Config conf;

    IconHandler iconh;
    LocaleUnit l10nUnit;

public:

    this (DataStore db, IconHandler iconHandler, LocaleUnit localeUnit)
    {
        import std.conv : to;

        dstore = db;
        iconh = iconHandler;
        conf = Config.get ();
        dtype = conf.metadataType;
        l10nUnit = localeUnit;

        compose = new Compose;
        //compose.setPrefix ("/usr");
        compose.setMediaResultDir (db.mediaExportPoolDir);
        compose.setMediaBaseurl ("");
        compose.setCheckMetadataEarlyFunc (&checkMetadataIntermediate, cast(void*) this);
        compose.addFlags (ComposeFlags.IGNORE_ICONS |  // we do custom icon processing
                          ComposeFlags.PROCESS_UNPAIRED_DESKTOP | // handle desktop-entry files without metainfo data
                          ComposeFlags.NO_FINAL_CHECK // we trigger the final check manually
                          );
        // we handle all threading, so the compose process doesn't also have to be threaded
        compose.removeFlags (ComposeFlags.USE_THREADS);

        // set CAInfo for any download operations performed by this AscCompose
        if (!conf.caInfo.empty)
            compose.setCainfo (conf.caInfo);

        // set dummy locale unit for advanced locale processing
        if (l10nUnit !is null)
            compose.setLocaleUnit (l10nUnit);

        // set max screenshot size in bytes, if size is limited
        if (conf.maxScrFileSize != 0)
            compose.setMaxScreenshotSize ((conf.maxScrFileSize * 1024 * 1024).to!ptrdiff_t);

        // enable or disable user-defined features
        if (conf.feature.validate)
            compose.addFlags (ComposeFlags.VALIDATE);
        else
            compose.removeFlags (ComposeFlags.VALIDATE);

        if (conf.feature.noDownloads)
            compose.removeFlags (ComposeFlags.ALLOW_NET);
        else
            compose.addFlags (ComposeFlags.ALLOW_NET);

        if (conf.feature.processLocale)
            compose.addFlags (ComposeFlags.PROCESS_TRANSLATIONS);
        else
            compose.removeFlags (ComposeFlags.PROCESS_TRANSLATIONS);

        if (conf.feature.processFonts)
            compose.addFlags (ComposeFlags.PROCESS_FONTS);
        else
            compose.removeFlags (ComposeFlags.PROCESS_FONTS);

        if (conf.feature.screenshotVideos)
            compose.addFlags (ComposeFlags.ALLOW_SCREENCASTS);
        else
            compose.removeFlags (ComposeFlags.ALLOW_SCREENCASTS);

        // guess an icon policy that matches the user settings best
        bool hasIconsRemote = false;
        bool hasIconsCached = false;
        foreach (const ref policy; conf.iconSettings) {
            if (policy.storeCached)
                hasIconsCached = true;
            if (policy.storeRemote)
                hasIconsRemote = true;
            if (hasIconsRemote && hasIconsCached)
                break;
        }
        compose.setIconPolicy (IconPolicy.BALANCED);
        if (!hasIconsRemote && hasIconsCached)
            compose.setIconPolicy (IconPolicy.ONLY_CACHED);
        if (!hasIconsCached && hasIconsRemote)
            compose.setIconPolicy (IconPolicy.ONLY_REMOTE);

        // register allowed custom keys with the composer
        foreach (const ref key; conf.allowedCustomKeys.byKey)
            compose.addCustomAllowed (key);
    }

    /**
     * Helper function for early asgen-specific metadata manipulation
     */
    extern(C)
    static void checkMetadataIntermediate (AscResult *cres, AscUnit *cunit, void *userData)
    {
        import ascompose.Result : Result;
        import asgen.config : EXTRA_METAINFO_FAKE_PKGNAME;

        auto self = cast(DataExtractor) userData;
        auto result = new Result (cres);

        auto cptsPtrArray = result.fetchComponents ();
        for (uint i = 0; i < cptsPtrArray.len; i++) {
            auto cpt = new Component (cast (AsComponent*) cptsPtrArray.index (i));
            auto gcid = result.gcidForComponent (cpt);

            // don't run expensive operations if the metadata already exists
            auto existingMData = self.dstore.getMetadata (self.dtype, gcid);
            if (existingMData is null)
                continue;

            // To account for packages which change their package name, we
            // also need to check if the package this component is associated
            // with matches ours.
            // If it doesn't, we can't just link the package to the component.
            bool samePkg = false;
            immutable bundleId = result.getBundleId;
            immutable bool isInjectedPkg = bundleId == EXTRA_METAINFO_FAKE_PKGNAME;
            if (isInjectedPkg) {
                // the fake package is exempt from the is-same-package check
                samePkg = true;
            } else {
                if (self.dtype == DataType.YAML) {
                    if (existingMData.canFind (format ("Package: %s\n", bundleId)))
                        samePkg = true;
                } else {
                    if (existingMData.canFind (format ("<pkgname>%s</pkgname>", bundleId)))
                        samePkg = true;
                }
            }

            if ((!samePkg) && (cpt.getKind != ComponentKind.WEB_APP)) {
                // The exact same metadata exists in a different package already, we emit an error hint.
                // ATTENTION: This does not cover the case where *different* metadata (as in, different summary etc.)
                // but with the *same ID* exists.
                // We only catch that kind of problem later.

                auto cdata = new Metadata ();
                cdata.setFormatStyle (FormatStyle.COLLECTION);
                cdata.setFormatVersion (self.conf.formatVersion);

                if (self.dtype == DataType.YAML)
                    cdata.parse (existingMData, FormatKind.YAML);
                else
                    cdata.parse (existingMData, FormatKind.XML);
                auto ecpt = cdata.getComponent ();

                const pkgNames = ecpt.getPkgnames;
                string pkgName = "(none)";
                if (!pkgNames.empty)
                    pkgName = pkgNames[0];
                result.addHint (cpt, "metainfo-duplicate-id", ["cid", cpt.getId,
                                                               "pkgname", pkgName]);
            }

            // drop the component as we already have processed it, but keep its
            // global ID so we can still register the ID with this package.
            if (!isInjectedPkg)
                result.removeComponentFull(cpt, false);
        }
    }

    /**
     * Helper function for DataExtractor.processPackage
     */
    extern(C)
    static GPtrArray *translateDesktopTextCallback (GKeyFile *dePtr, const(char) *text, void *userData)
    {
        import glib.KeyFile : KeyFile;
        import glib.c.functions;
        import std.string : fromStringz, toStringz;

        auto pkg = *cast(Package*) userData;
        auto de = new KeyFile (dePtr, false);
        auto res = g_ptr_array_new_with_free_func (&g_free);

        auto translations = pkg.getDesktopFileTranslations (de, cast(string) text.fromStringz);
        foreach (ref key, ref value; translations) {
            g_ptr_array_add (res, g_strdup (key.toStringz));
            g_ptr_array_add (res, g_strdup (value.toStringz));
        }

        return res;
    }

    GeneratorResult processPackage (Package pkg)
    {
        import ascompose.Result : Result;

        // reset compose instance to clear data from any previous invocation
        compose.reset ();

        // set external desktop-entry translation function, if needed
        immutable externalL10n = pkg.hasDesktopFileTranslations;
        compose.setDesktopEntryL10nFunc (externalL10n? &translateDesktopTextCallback : null,
                                         externalL10n? &pkg : null);

        // wrap package into unit, so AppStream Compose can work with it
        auto unit = new PackageUnit (pkg);
        compose.addUnit (unit);

        // process all data
        compose.run (null);
        auto resultsArray = compose.getResults ();

        // we processed one unit, so should always generate one result
        if (resultsArray.len != 1) {
            logError ("Expected %s result for data extraction, but retrieved %s.", 1, resultsArray.len);
            assert (resultsArray.len == 1);
        }

        // create result wrapper
        auto gres = GeneratorResult (new Result (cast (AscResult*) resultsArray.index (0)),
                                     pkg);

        // process icons and perform additional refinements
        auto cptsPtrArray = gres.fetchComponents ();
        for (uint i = 0; i < cptsPtrArray.len; i++) {
            auto cpt = new Component (cast (AsComponent*) cptsPtrArray.index (i));
            immutable ckind = cpt.getKind;

            // find & store icons
            iconh.process (gres, cpt);
            if (gres.isIgnored (cpt))
                continue;

            // add fallback long descriptions only for desktop apps, console apps and web apps
            if (cpt.getMergeKind != MergeKind.NONE)
                continue;
            if (ckind != ComponentKind.DESKTOP_APP && ckind != ComponentKind.CONSOLE_APP && ckind != ComponentKind.WEB_APP)
                continue;

            // inject package descriptions, if needed
            auto flags = cpt.getValueFlags;
            cpt.setValueFlags (flags | AsValueFlags.NO_TRANSLATION_FALLBACK);

            cpt.setActiveLocale ("C");
            if (!cpt.getDescription.empty)
                continue;

            // component doesn't have a long description, add one from the packaging.
            auto desc_added = false;
            foreach (ref lang, ref desc; pkg.description) {
                    cpt.setDescription (desc, lang);
                    desc_added = true;
            }

            if (desc_added) {
                // we only add the "description-from-package" tag if we haven't alreaey
                // emitted a "no-metainfo" tag, to avoid two hints explaining the same thing
                if (!gres.hasHint (cpt, "no-metainfo")) {
                    if (!gres.addHint (cpt, "description-from-package"))
                        continue;
                }
            } else {
                if (!gres.addHint (cpt, "description-missing", ["kind": AsUtils.componentKindToString (ckind)]))
                    continue;
            }
        }

        // handle GStreamer integration (usually for Ubuntu)
        if (conf.feature.processGStreamer && !pkg.gst.isNull && pkg.gst.get.isNotEmpty) {
            auto data = appender!string;
            data.reserve(200);

            auto cpt = new Component ();
            cpt.setId (pkg.name);
            cpt.setKind (ComponentKind.CODEC);
            cpt.setName ("GStreamer Multimedia Codecs", "C");
            foreach (ref lang, ref desc; pkg.summary) {
                cpt.setSummary (desc, lang);
                data ~= desc;
            }

            gres.addComponent (cpt, data.data.toStaticGBytes);
        }

        // perform final checks
        compose.finalizeResults ();

        // do our own final validation
        cptsPtrArray = gres.fetchComponents ();
        for (uint i = 0; i < cptsPtrArray.len; i++) {
            auto cpt = new Component (cast (AsComponent*) cptsPtrArray.index (i));
            immutable ckind = cpt.getKind;

            if (cpt.getMergeKind != MergeKind.NONE)
                continue;

            if (cpt.getPkgnames.empty) {
                    // no packages are associated with this component

                    if (ckind != ComponentKind.WEB_APP &&
                        ckind != ComponentKind.OPERATING_SYSTEM &&
                        ckind != ComponentKind.REPOSITORY) {
                            // this component is not allowed to have no installation candidate
                            if (!cpt.hasBundle) {
                                if (!gres.addHint (cpt, "no-install-candidate"))
                                    continue;
                            }
                    }
            } else {
                // packages are associated with this component

                if (pkg.kind == PackageKind.FAKE) {
                    import std.array : array;
                    import asgen.config : EXTRA_METAINFO_FAKE_PKGNAME;
                    import std.algorithm.iteration : filter;

                    // drop any association with the dummy package
                    auto pkgnames = cpt.getPkgnames;
                    cpt.setPkgnames (array(pkgnames.filter!(a => a != EXTRA_METAINFO_FAKE_PKGNAME)));
                }
            }
        }

        // clean up and return result
        pkg.finish ();
        return gres;
    }
}
