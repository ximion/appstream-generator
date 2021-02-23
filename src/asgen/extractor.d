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
import ascompose.MetaInfoUtils : MetaInfoUtils;
import glib.Bytes : Bytes;

import asgen.config;
import asgen.hintregistry;
import asgen.result;
import asgen.backends.interfaces;
import asgen.datastore;
import asgen.handlers;
import asgen.utils : componentGetStockIcon, toStaticGBytes;


final class DataExtractor
{

private:
    Component[] cpts;
    Hint[] hints;

    DataStore dstore;
    IconHandler iconh;
    LocaleHandler localeh;
    Config conf;
    DataType dtype;

public:

    this (DataStore db, IconHandler iconHandler, LocaleHandler localeHandler)
    {
        dstore = db;
        iconh = iconHandler;
        localeh = localeHandler;
        conf = Config.get ();
        dtype = conf.metadataType;
    }

    static void validateMetaInfoData (GeneratorResult gres, Component cpt,
                                      Bytes bytes, const string miBasename)
    {
        import appstream.Validator : Validator;
        import glib.c.types : GDestroyNotify;

        // create thread-local validator for efficiency
        static Validator validator = null;
        if (validator is null)
            validator = new Validator;

        MetaInfoUtils.validateMetainfoDataForComponent(gres, validator, cpt,
                                                       bytes,
                                                       miBasename);
    }

    GeneratorResult processPackage (Package pkg)
    {
        // create a new result container
        auto gres = new GeneratorResult (pkg);

        // prepare a list of metadata files which interest us
        string[string] desktopFiles;
        string[] metadataFiles;
        foreach (ref fname; pkg.contents) {
            if ((fname.startsWith ("/usr/share/applications")) && (fname.endsWith (".desktop"))) {
                desktopFiles[baseName (fname)] = fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/metainfo/")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
            if ((fname.startsWith ("/usr/share/appdata/")) && (fname.endsWith (".xml"))) {
                metadataFiles ~= fname;
                continue;
            }
        }

        // create new AppStream metadata parser
        auto mdata = scoped!Metadata ();
        mdata.setLocale ("ALL");
        mdata.setFormatStyle (FormatStyle.METAINFO);

        // now process metainfo XML files
        foreach (ref const mfname; metadataFiles) {
            auto dataBytesRaw = pkg.getFileData (mfname);
            if (dataBytesRaw.empty)
                continue;
            auto dataBytes = dataBytesRaw.toStaticGBytes;

            mdata.clearComponents ();
            auto cpt = MetaInfoUtils.parseMetainfoData (gres, mdata, dataBytes, mfname);
            if (cpt is null)
                continue;

            // get component ID (it must exist and not be empty, as validated by the metainfo parser)
            auto cid = cpt.getId;

            // check for legacy path
            if (mfname.startsWith ("/usr/share/appdata/")) {
                gres.addHint (null, "legacy-metainfo-directory", ["fname": mfname.baseName]);
            }

            // we need to add the version to re-download screenshot on every new upload.
            // otherwise, screenshots would only get updated if the actual metadata file was touched.
            gres.updateComponentGcidWithString (cpt, pkg.ver);

            // validate the desktop-id launchables and merge the desktop file data
            // in case we find it.
            auto launch = cpt.getLaunchable (LaunchableKind.DESKTOP_ID);
            if (launch !is null) {
                auto entries = launch.getEntries ();

                for (uint i = 0; i < entries.len; i++) {
                    import std.string : fromStringz;
                    import std.conv : to;
                    immutable desktopId = to!string ((cast(char*) entries.index (i)).fromStringz);

                    immutable dfname = desktopFiles.get (desktopId, null);
                    if (dfname.empty) {
                        gres.addHint (cpt, "missing-launchable-desktop-file", ["desktop_id": desktopId]);
                    } else if (i == 0) {
                        // always only try to merge in the first .desktop-ID, because if there are multiple
                        // launchables defined, the component *must* not depend on the data in one
                        // single .desktop file anyway.

                        // update component with .desktop file data, ignoring NoDisplay field
                        const ddataBytes = pkg.getFileData (dfname);
                        auto ddata = cast(string) ddataBytes;
                        parseDesktopFile (gres, cpt, dfname, ddata, true);

                        // update GCID checksum
                        gres.updateComponentGcid (cpt, ddataBytes.toStaticGBytes);

                        // drop the .desktop file from the list, it has been handled
                        desktopFiles.remove (desktopId);
                    }
                }
            }

            // For compatibility, we try other methods than using the "launchable"
            // tag to merge in .desktop files, but only if we actually need to do that.
            // At the moment we determine whether a .desktop file is needed by checking
            // if the metainfo file defines an icon (which is commonly provided by the .desktop
            // file instead of the metainfo file).
            // This heuristic is, of course, not ideal, which is why everything should have a launchable tag.
            if ((cpt.getKind == ComponentKind.DESKTOP_APP) && (componentGetStockIcon (cpt).isNull)) {
                auto dfname = desktopFiles.get (cid, null);

                if (dfname.empty)
                    dfname = desktopFiles.get (cid ~ ".desktop", null);
                if (dfname.empty) {
                    // no .desktop file was found and this component does not
                    // define an icon - this means that a .desktop file is required
                    // and can not be omitted, so we stop processing here.
                    // Otherwise we take the data and see how far we get.

                    // finalize GCID checksum and continue
                    gres.updateComponentGcid (cpt, dataBytes);

                    gres.addHint (cpt, "missing-desktop-file");
                    // we have a desktop-application component, but no .desktop file.
                    // This is an error we can not recover from.
                    continue;
                } else {
                    // update component with .desktop file data, ignoring NoDisplay field
                    const ddataBytesRaw = pkg.getFileData (dfname);
                    auto ddataBytes = ddataBytesRaw.toStaticGBytes;
                    parseDesktopFile (gres, cpt, dfname, cast(string) ddataBytesRaw, true);

                    // update GCID checksum
                    gres.updateComponentGcid (cpt, ddataBytes);

                    // drop the .desktop file from the list, it has been handled
                    desktopFiles.remove (cid);
                }
            }

            // do a validation of the file. Validation may be slow, so we allow
            // the user to disable this feature.
            if (conf.feature.validate) {
                if (!dstore.metadataExists (dtype, gres.gcidForComponent (cpt)))
                    validateMetaInfoData (gres, cpt, dataBytes, mfname.baseName);
            }
        }

        // process the remaining .desktop files
        foreach (ref dfname; desktopFiles.byValue) {
            auto ddataBytesRaw = pkg.getFileData (dfname);
            auto ddataBytes = ddataBytesRaw.toStaticGBytes;
            auto cpt = parseDesktopFile (gres, null, dfname, cast(string) ddataBytesRaw, false);
            if (cpt !is null)
                gres.updateComponentGcid (cpt, ddataBytes);
        }

        if (conf.feature.processGStreamer && !pkg.gst.isNull && pkg.gst.get.isNotEmpty) {
            auto data = appender!string;
            data.reserve(512);

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

        auto hasFontComponent = false;
        auto cptsPtrArray = gres.fetchComponents ();
        for (uint i = 0; i < cptsPtrArray.len; i++) {
            auto cpt = new Component (cast (AsComponent*) cptsPtrArray.index (i));
            auto gcid = gres.gcidForComponent (cpt);

            // don't run expensive operations if the metadata already exists
            auto existingMData = dstore.getMetadata (dtype, gcid);
            if (existingMData !is null) {
                // To account for packages which change their package name, we
                // also need to check if the package this component is associated
                // with matches ours.
                // If it doesn't, we can't just link the package to the component.
                bool samePkg = false;
                if (dtype == DataType.YAML) {
                    if (existingMData.canFind (format ("Package: %s\n", pkg.name)))
                        samePkg = true;
                } else {
                    if (existingMData.canFind (format ("<pkgname>%s</pkgname>", pkg.name)))
                        samePkg = true;
                }

                if ((!samePkg) && (cpt.getKind != ComponentKind.WEB_APP)) {
                    // The exact same metadata exists in a different package already, we emit an error hint.
                    // ATTENTION: This does not cover the case where *different* metadata (as in, different summary etc.)
                    // but with the *same ID* exists.
                    // We only catch that kind of problem later.

                    auto cdata = new Metadata ();
                    cdata.setFormatStyle (FormatStyle.COLLECTION);
                    cdata.setFormatVersion (conf.formatVersion);

                    if (dtype == DataType.YAML)
                        cdata.parse (existingMData, FormatKind.YAML);
                    else
                        cdata.parse (existingMData, FormatKind.XML);
                    auto ecpt = cdata.getComponent ();

                    const pkgNames = ecpt.getPkgnames;
                    string pkgName = "(none)";
                    if (!pkgNames.empty)
                        pkgName = pkgNames[0];
                    gres.addHint (cpt, "metainfo-duplicate-id", ["cid": cpt.getId (), "pkgname": pkgName]);
                }

                continue;
            }

            // find & store icons
            iconh.process (gres, cpt);
            if (gres.isIgnored (cpt))
                continue;

            // download and resize screenshots.
            // we don't even need to call this if no downloads are allowed.
            if (!conf.feature.noDownloads)
                processScreenshots (gres, cpt, dstore.mediaExportPoolDir);

            // process locale information.
            if (conf.feature.processLocale)
                localeh.processLocaleInfoForComponent (gres, cpt);

            // we don't want to run expensive font processing if we don't have a font component.
            // since the font handler needs to load all font data prior to processing the component,
            // for efficiency we only record whether we need to process fonts here and then handle
            // them at a later step.
            // This improves performance for a package that contains multiple font components.
            if (cpt.getKind () == ComponentKind.FONT)
                hasFontComponent = true;
        }

        // render font previews and extract font metadata (if any of the components is a font)
        if (conf.feature.processFonts) {
            if (hasFontComponent)
                processFontData (gres, dstore.mediaExportPoolDir);
        }

        // this removes invalid components and cleans up the result
        gres.finalize ();
        pkg.finish ();

        return gres;
    }
}
