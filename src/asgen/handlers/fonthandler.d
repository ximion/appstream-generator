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

module asgen.handlers.fonthandler;

import std.path : baseName, buildPath;
import std.array : appender, replace;
import std.string : format, fromStringz, startsWith, endsWith, strip, toLower;
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
import asgen.handlers.iconhandler : wantedIconSizes;


private immutable fontScreenshotSizes = [ImageSize (1024, 78), ImageSize (640, 48)];

void processFontData (GeneratorResult gres, string mediaExportDir)
{
    import asgen.fcmutex;

    auto hasFonts = false;
    foreach (ref cpt; gres.getComponents ()) {
        if (cpt.getKind () != ComponentKind.FONT)
            continue;
        hasFonts = true;
        break;
    }

    // nothing to do if we don't have fonts
    if (!hasFonts)
        return;

    // NOTE: Thanks to Fontconfig being non-threadsafe and sometimes being confused if you
    // just create multiple configurations in multiple threads, we need to run almost all
    // font operations synchronized, which sucks.
    // FreeType / Cairo also seems to have issues here, causing the generator to crash
    // at random, or deadlock reliably when trying to get a Cairo/FT-internal Mutex.
    // Pay attention that enterFontconfigCriticalSection() are always balanced out with their
    // leave counterpart, otherwise we will deadlock quickly.
    processFontDataInternal (gres, mediaExportDir);
}

void processFontDataInternal (GeneratorResult gres, string mediaExportDir)
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
            gres.addHint (null, "pkg-extract-error", ["fname": fname.baseName, "pkg_fname": gres.pkg.filename.baseName, "error": e.msg]);
            return;
        }

        immutable fontBaseName = fname.baseName;
        logDebug ("Reading font %s", fontBaseName);

        // the font class locks the global mutex internally when reading data with Fontconfig
        Font font;
        try {
            font = new Font (fdata, fontBaseName);
        } catch (Exception e) {
            gres.addHint (null, "font-load-error", ["fname": fontBaseName, "pkg_fname": gres.pkg.filename.baseName, "error": e.msg]);
            return;
        }
        allFonts[font.fullName.toLower] = font;
    }

    foreach (ref cpt; gres.getComponents ()) {
        import asgen.fcmutex;

        if (cpt.getKind () != ComponentKind.FONT)
            continue;

        processFontDataForComponent (gres, cpt, allFonts, mediaExportDir);
    }
}

void processFontDataForComponent (GeneratorResult gres, Component cpt, Font[string] allFonts, string mediaExportDir)
{
    immutable gcid = gres.gcidForComponent (cpt);
    if (gcid is null) {
        gres.addHint (cpt, "internal-error", "No global ID could be found for the component.");
        return;
    }

    auto fontHints = appender!(string[]);
    auto provided = cpt.getProvidedForKind (ProvidedKind.FONT);
    if (provided !is null) {
        auto fontHintsArr = provided.getItems ();

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
        foreach (ref font; allFonts.byValue)
            selectedFonts ~= font;
    } else {
        // find fonts based on the hints we have
        // the hint as well as the dictionary keys are all lowercased, so we
        // can do case-insensitive matching here.
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
private bool renderFontIcon (GeneratorResult gres, Font font, immutable string cptIconsPath, Component cpt)
{
    foreach (ref size; wantedIconSizes) {
        immutable path = buildPath (cptIconsPath, size.toString);
        std.file.mkdirRecurse (path);

        immutable fid = font.id;
        immutable iconName = format ("%s_%s.png", gres.pkgname,  fid);
        immutable iconStoreLocation = buildPath (path, iconName);

        if (!std.file.exists (iconStoreLocation)) {
            // we didn't create an icon yet - render it
            auto cv = new Canvas (size.width, size.height);
            cv.drawTextLine (font, font.sampleIconText);
            cv.savePng (iconStoreLocation);
        }

        auto icon = new Icon ();
        icon.setKind (IconKind.CACHED);
        icon.setWidth (size.width);
        icon.setHeight (size.height);
        icon.setName (iconName);
        cpt.addIcon (icon);
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
