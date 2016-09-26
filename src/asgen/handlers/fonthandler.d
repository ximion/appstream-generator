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
import std.array : appender;
import std.string : format, fromStringz, startsWith, endsWith, strip;
import std.algorithm : remove;
import std.conv : to;
import appstream.Component;
import appstream.Icon;
import appstream.Screenshot;
static import std.file;

import asgen.utils;
import asgen.logging;
import asgen.result;
import asgen.image : Canvas;
import asgen.font : Font;
import asgen.handlers.iconhandler : wantedIconSizes;


void processFontData (GeneratorResult gres, Component cpt, string mediaExportDir)
{
    if (cpt.getKind () != ComponentKind.FONT)
        return;

    // Thanks to Fontconfig being non-threadsafe and sometimes being confused if you
    // just create multiple configurations in multiple threads, we need to run all
    // font operations synchronized, which sucks.
    // We can not even only make parts of the process synchronized, since we or other
    // classes are dealing with a Font object all the time.
    synchronized {
        processFontDataInternal (gres, cpt, mediaExportDir);
    }
}

void processFontDataInternal (GeneratorResult gres, Component cpt, string mediaExportDir)
{
    string[] fontHints;
    auto provided = cpt.getProvidedForKind (ProvidedKind.FONT);
    if (provided !is null) {
        auto fontHintsArr = provided.getItems ();

        for (uint i = 0; i < fontHintsArr.len; i++) {
            auto fontFname = (cast(char*) fontHintsArr.index (i)).fromStringz;
            fontHints ~= to!string (fontFname);
        }
    }

    // look for interesting fonts
    auto includeFonts = appender!(string[]);
    if (fontHints.length == 0) {
        // we had no fonts defined in the metainfo file, just select all fonts that
        // we can find.
        foreach (ref fname; gres.pkg.contents) {
            if (!fname.startsWith ("/usr/share/fonts/"))
                continue;
            if (!fname.endsWith (".ttf", ".otf"))
                continue;
            // TODO: Can we support more font types?
            includeFonts ~= fname;
        }
    } else {
        foreach (ref fname; gres.pkg.contents) {
            if (!fname.startsWith ("/usr/share/fonts/"))
                continue;

            foreach (ref name; fontHints) {
                if (fname.endsWith (name)) {
                    includeFonts ~= fname;
                    //fontHints.remove (name);
                    break;
                }
            }
        }
    }

    auto hasIcon = false;
    foreach (ref fontFile; includeFonts.data) {
        const(ubyte)[] fdata;
        try {
            fdata = gres.pkg.getFileData (fontFile);
        } catch (Exception e) {
            gres.addHint(cpt, "pkg-extract-error", ["fname": fontFile.baseName, "pkg_fname": gres.pkg.filename.baseName, "error": e.msg]);
            return;
        }

        immutable gcid = gres.gcidForComponent (cpt);
        if (gcid is null) {
            gres.addHint (cpt, "internal-error", "No global ID could be found for the component.");
            return;
        }

        logDebug ("Rendering font data for %s", gcid);

        // data export paths
        immutable cptIconsPath = buildPath (mediaExportDir, gcid, "icons");
        immutable cptScreenshotsPath = buildPath (mediaExportDir, gcid, "screenshots");

        // TODO: Catch errors
        auto font = new Font (fdata, fontFile.baseName);

        // add language information
        foreach (ref lang; font.languages) {
            cpt.addLanguage (lang, 100);
        }

        // render an icon for our font
        if (!hasIcon)
            hasIcon = renderFontIcon (gres,
                                      font,
                                      fontFile,
                                      cptIconsPath,
                                      cpt);
    }
}

/**
 * Render an icon for this font package using one of its fonts.
 * (Since we have no better way to do this, we just pick the first font
 * at time)
 **/
private bool renderFontIcon (GeneratorResult gres, Font font, string fontFile, immutable string cptIconsPath, Component cpt)
{
    foreach (ref size; wantedIconSizes) {
        immutable path = buildPath (cptIconsPath, size.toString);
        std.file.mkdirRecurse (path);

        auto fid = font.id;
        if (fid is null)
            fid = fontFile.baseName;

        immutable iconName = format ("%s_%s.png", gres.pkgname,  fid);
        immutable iconStoreLocation = buildPath (path, iconName);

        if (!std.file.exists (iconStoreLocation)) {
            // we didn't create an icon yet - render it
            auto cv = new Canvas (size.width, size.height);
            cv.writeText (font, font.sampleIconText, 3, 1);
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
