/*
 * Copyright (C) 2016-2018 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.handlers.fonthandler;

import std.path : baseName, buildPath;
import std.array : appender, replace, empty;
import std.string : format, fromStringz, startsWith, endsWith, strip, toLower;
import std.algorithm : map;
import std.conv : to;
import appstream.Component;
import appstream.Icon;
import appstream.Screenshot;
static import appstream.Image;
static import std.file;

import asgen.utils;
import asgen.logging;
import asgen.result;
import asgen.image : Canvas;
import asgen.font : Font;
import asgen.config : Config, IconPolicy;


private immutable fontScreenshotSizes = [ImageSize (1024, 78), ImageSize (640, 48)];

void processFontData (GeneratorResult gres, string mediaExportDir)
{
    // create a map of all fonts we have in this package
    Font[string] allFonts;
    foreach (ref fname; gres.pkg.contents) {
        if (!fname.startsWith ("/usr/share/fonts/"))
            continue;
        if (!fname.endsWith (".ttf", ".otf"))
            continue;
        // TODO: Can we support more font types?

        const(ubyte)[] fdata;
        try {
            fdata = gres.pkg.getFileData (fname);
        } catch (Exception e) {
            gres.addHint (null, "pkg-extract-error", ["fname": fname.baseName,
                                                      "pkg_fname": gres.pkg.getFilename.baseName,
                                                      "error": e.msg]);
            return;
        }

        immutable fontBaseName = fname.baseName;
        logDebug ("Reading font %s", fontBaseName);

        // the font class locks the global mutex internally when reading data with Fontconfig
        Font font;
        try {
            font = new Font (fdata, fontBaseName);
        } catch (Exception e) {
            gres.addHint (null, "font-load-error", ["fname": fontBaseName,
                                                    "pkg_fname": gres.pkg.getFilename.baseName,
                                                    "error": e.msg]);
            return;
        }
        allFonts[font.fullName.toLower] = font;
    }

    foreach (ref cpt; gres.getComponents ()) {
        if (cpt.getKind () != ComponentKind.FONT)
            continue;

        processFontDataForComponent (gres, cpt, allFonts, mediaExportDir);
    }
}

void processFontDataForComponent (GeneratorResult gres, Component cpt, ref Font[string] allFonts, string mediaExportDir)
{
    immutable gcid = gres.gcidForComponent (cpt);
    if (gcid is null) {
        gres.addHint (cpt, "internal-error", "No global ID could be found for the component.");
        return;
    }

    auto iconPolicy = Config.get.iconSettings;

    auto fontHints = appender!(string[]);
    auto provided = cpt.getProvidedForKind (ProvidedKind.FONT);
    if (provided !is null) {
        auto fontHintsArr = provided.getItems ();
        fontHints.reserve (fontHintsArr.len);

        for (uint i = 0; i < fontHintsArr.len; i++) {
            auto fontFullName = (cast(char*) fontHintsArr.index (i)).fromStringz;
            fontHints ~= to!string (fontFullName).toLower;
        }
    }

    // data export paths
    immutable cptIconsPath = buildPath (mediaExportDir, gcid, "icons");
    immutable cptScreenshotsPath = buildPath (mediaExportDir, gcid, "screenshots");

    // if we have no fonts hints, we simply process all the fonts
    // we found n this package.
    auto selectedFonts = appender!(Font[]);
    if (fontHints.data.length == 0) {
        selectedFonts.reserve (allFonts.length);
        foreach (ref font; allFonts.byValue)
            selectedFonts ~= font;
    } else {
        // find fonts based on the hints we have
        // the hint as well as the dictionary keys are all lowercased, so we
        // can do case-insensitive matching here.
        selectedFonts.reserve (fontHints.data.length);
        foreach (ref fontHint; fontHints.data) {
            auto fontP = fontHint in allFonts;
            if (fontP is null)
                continue;
            selectedFonts ~= *fontP;
        }
    }

    // we have nothing to do if we did not select any font
    // (this is a bug, since we filtered for font metainfo previously)
    if (selectedFonts.data.length == 0) {
        gres.addHint (cpt, "font-metainfo-but-no-font");
        return;
    }

    // language information of fonts is often wrong. In case there was a metainfo file
    // with languages explicitly set, we take the first language and prefer that over the others.
    auto cptLanguages = cpt.getLanguages ();
    if (cptLanguages !is null) {
        auto firstLang = (cast(char*) cptLanguages.first.data).fromStringz;

        foreach (ref font; selectedFonts.data)
            font.preferredLanguage = firstLang.to!string;

        // add languages mentioned in the metainfo file to list of supported languages
        // of the respective font
        auto item = cptLanguages.first.next;
        while (item !is null) {

            foreach (ref font; selectedFonts.data)
                font.addLanguage (to!string ((cast(char*) item.data).fromStringz));

            item = item.next;
        }
    }

    logDebug ("Rendering font data for %s", gcid);

    // process font files
    auto hasIcon = false;
    foreach (ref font; selectedFonts.data) {
        logDebug ("Processing font '%s'", font.id);

        // add language information
        foreach (ref lang; font.languages) {
            cpt.addLanguage (lang, 80);
        }

        // render an icon for our font
        if (!hasIcon)
            hasIcon = renderFontIcon (gres,
                                      iconPolicy,
                                      font,
                                      cptIconsPath,
                                      cpt);
    }

    // render all sample screenshots for all font styles we have
    renderFontScreenshots (gres,
                           selectedFonts.data,
                           cptScreenshotsPath,
                           cpt);
}

/**
 * Render an icon for this font package using one of its fonts.
 * (Since we have no better way to do this, we just pick the first font
 * at time)
 **/
private bool renderFontIcon (GeneratorResult gres, IconPolicy[] iconPolicy, Font font, immutable string cptIconsPath, Component cpt)
{
    foreach (ref policy; iconPolicy) {
        if (!policy.storeIcon)
            continue;
        immutable size = policy.iconSize;
        immutable path = buildPath (cptIconsPath, size.toString);
        std.file.mkdirRecurse (path);

        // check if we have a custom icon text value (useful for symbolic fonts)
        immutable customIconText = cpt.getCustomValue ("FontIconText");
        if (!customIconText.empty)
            font.sampleIconText = customIconText; // Font will ensure that the value does not exceed 3 chars

        immutable fid = font.id;
        immutable iconName = format ("%s_%s.png", gres.pkgname,  fid);
        immutable iconStoreLocation = buildPath (path, iconName);

        if (!std.file.exists (iconStoreLocation)) {
            // we didn't create an icon yet - render it
            auto cv = new Canvas (size.width, size.height);
            cv.drawTextLine (font, font.sampleIconText);
            cv.savePng (iconStoreLocation);
        }

        if (policy.storeCached) {
            auto icon = new Icon ();
            icon.setKind (IconKind.CACHED);
            icon.setWidth (size.width);
            icon.setHeight (size.height);
            icon.setScale (size.scale);
            icon.setName (iconName);
            cpt.addIcon (icon);
        }
        if (policy.storeRemote) {
            immutable gcid = gres.gcidForComponent (cpt);
            if (gcid is null) {
                gres.addHint (cpt, "internal-error", "No global ID could be found for the component, could not add remote font icon.");
                return true;
            }
            immutable remoteIconUrl = buildPath (gcid, "icons", size.toString, iconName);

            auto icon = new Icon ();
            icon.setKind (IconKind.REMOTE);
            icon.setWidth (size.width);
            icon.setHeight (size.height);
            icon.setScale (size.scale);
            icon.setUrl (remoteIconUrl);
            cpt.addIcon (icon);
        }
    }

    return true;
}

/**
 * Render a "screenshot" sample for this font.
 **/
private bool renderFontScreenshots (GeneratorResult gres, Font[] fonts, immutable string cptScreenshotsPath, Component cpt)
{
    std.file.mkdirRecurse (cptScreenshotsPath);

    auto first = true;
    foreach (ref font; fonts) {
        immutable fid = font.id;
        if (fid is null) {
            logWarning ("%s: Ignored font screenshot rendering due to missing ID:", cpt.getId ());
            continue;
        }

        auto scr = new Screenshot ();
        if (first)
            scr.setKind (ScreenshotKind.DEFAULT);
        else
            scr.setKind (ScreenshotKind.EXTRA);
        scr.setCaption ("%s %s".format (font.family, font.style), "C");

        if (first)
            first = false;

        // check if we have a custom sample text value (useful for symbolic fonts)
        // we set this value for every fonr in the font-bundle, there is no way for this
        // hack to select which font face should have the sample text.
        // Since this hack only affects very few exotic fonts and should generally not
        // be used, this should not be an issue.
        immutable customSampleText = cpt.getCustomValue ("FontSampleText");
        if (!customSampleText.empty)
            font.sampleIconText = customSampleText;

        auto cptScreenshotsUrl = buildPath (gres.gcidForComponent (cpt), "screenshots");
        foreach (ref size; fontScreenshotSizes) {
            immutable imgName = "image-%s_%s.png".format (fid, size.toString);
            immutable imgFileName = buildPath (cptScreenshotsPath, imgName);
            immutable imgUrl = buildPath (cptScreenshotsUrl, imgName);


            if (!std.file.exists (imgFileName)) {
                // we didn't create s screenshot yet - render it
                auto cv = new Canvas (size.width, size.height);
                cv.drawTextLine (font, font.sampleText);
                cv.savePng (imgFileName);
            }

            auto img = new appstream.Image.Image ();
            img.setKind (ImageKind.THUMBNAIL);
            img.setWidth (size.width);
            img.setHeight (size.height);
            img.setUrl (imgUrl);

            scr.addImage (img);
        }

        cpt.addScreenshot (scr);
    }

    return true;
}
