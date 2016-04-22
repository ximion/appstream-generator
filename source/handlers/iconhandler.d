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

module ag.handlers.iconhandler;

import std.stdio;
import std.string;
import std.array : replace;
import std.path : baseName, buildPath;
import std.uni : toLower;
import std.file : mkdirRecurse;
import std.algorithm : canFind;
import std.variant;
import std.parallelism;
import glib.KeyFile;
import appstream.Component;
import appstream.Icon;

import ag.utils;
import ag.logging;
import ag.result;
import ag.image;
import ag.backend.intf;
import ag.contentscache;
import ag.std.concurrency.generator;


// all image extensions that we recognize as possible for icons.
// the most favorable file extension needs to come first to prefer it
private immutable possibleIconExts = [".png", ".jpg", ".svgz", ".svg", ".gif", ".ico", ".xpm"];

// the image extensions that we will actually allow software to have.
private immutable allowedIconExts  = [".png", ".jpg", ".svgz", ".svg"];

private immutable wantedIconSizes  = [ImageSize (64), ImageSize (128)];


/**
 * Describes an icon theme as specified in the XDG theme spec.
 */
private class Theme
{

private:
    string name;
    Algebraic!(int, string)[string][] directories;

public:

    this (string name, string indexData)
    {
        this.name = name;

        auto index = new KeyFile ();
        index.loadFromData (indexData, -1, GKeyFileFlags.NONE);

        ulong dummy;
        foreach (section; index.getGroups (dummy)) {
            string type;
            string context;
            int threshold;
            int size;
            int minSize;
            int maxSize;
            try {
                size = index.getInteger (section, "Size");
                context = index.getString (section, "Context");
            } catch { continue; }

            try {
                threshold = index.getInteger (section, "Threshold");
            } catch {
                threshold = 2;
            }
            try {
                type = index.getString (section, "Type");
            } catch {
                type = "Threshold";
            }
            try {
                minSize = index.getInteger (section, "MinSize");
            } catch {
                minSize = size;
            }
            try {
                maxSize = index.getInteger (section, "MaxSize");
            } catch {
                maxSize = size;
            }

            if (size == 0)
                continue;
            auto themedir = [
                "path": Algebraic!(int, string) (section),
                "type": Algebraic!(int, string) (type),
                "size": Algebraic!(int, string) (size),
                "minsize": Algebraic!(int, string) (minSize),
                "maxsize": Algebraic!(int, string) (maxSize),
                "threshold": Algebraic!(int, string) (threshold)
            ];
            directories ~= themedir;
        }
    }

    this (string name, Package pkg)
    {
        auto indexData = pkg.getFileData (buildPath ("/usr/share/icons", name, "index.theme"));
        this (name, indexData);
    }

    private bool directoryMatchesSize (Algebraic!(int, string)[string] themedir, ImageSize size)
    {
        string type = themedir["type"].get!(string);
        if (type == "Fixed")
            return size.toInt () == themedir["size"].get!(int);
        if (type == "Scalable") {
            if ((themedir["minsize"].get!(int) <= size.toInt ()) && (size.toInt () <= themedir["maxsize"].get!(int)))
                return true;
            return false;
        }
        if (type == "Threshold") {
            auto themeSize = themedir["size"].get!(int);
            auto th = themedir["threshold"].get!(int);
            if (((themeSize - th) <= size.toInt ()) && (size.toInt () <= (themeSize + th)))
                return true;
            return false;
        }

        return false;
    }

    /**
     * Returns an iteratable of possible icon filenames that match 'name' and 'size'.
     **/
    auto matchingIconFilenames (string iname, ImageSize size)
    {
        auto gen = new Generator!string (
        {
            foreach (themedir; this.directories) {
                if (directoryMatchesSize (themedir, size)) {
                    // best filetype needs to come first to be preferred, only types allowed by the spec are handled at all
                    foreach (extension; ["png", "svgz", "svg", "xpm"])
                        yield (format ("/usr/share/icons/%s/%s/%s.%s", this.name, themedir["path"].get!(string), iname, extension));
                }
            }
        });

        return gen;
    }
}


/**
 * Finds icons in a software archive and stores them in the
 * correct sizes for a given AppStream component.
 */
class IconHandler
{

private:
    string mediaExportPath;

    Theme[] themes;
    Package[string] iconFiles;
    string[] themeNames;

public:

    this (string mediaPath, Package[string] pkgMap, string iconTheme = null)
    {
        logDebug ("Creating new IconHandler");

        mediaExportPath = mediaPath;

        // Preseeded theme names.
        // * prioritize hicolor, because that's where apps often install their upstream icon
        // * then look at the theme given in the config file
        // * allow Breeze icon theme, needed to support KDE apps (they have no icon at all, otherwise...)
        // * in rare events, GNOME needs the same treatment, so special-case Adwaita as well
        // * We need at least one icon theme to provide the default XDG icon spec stock icons.
        //   A fair take would be to select them between KDE and GNOME at random, but for consistency and
        //   because everyone hates unpredictable behavior, we sort alphabetically and prefer Adwaita over Breeze.
        themeNames = ["hicolor"];
        if (iconTheme !is null)
            themeNames ~= iconTheme;
        themeNames ~= "Adwaita";
        themeNames ~= "breeze";

        Package getPackage (string pkid)
        {
            if (pkid is null)
                return null;
            auto pkgP = (pkid in pkgMap);
            if (pkgP is null)
                return null;
            else
                return *pkgP;
        }

        // open package contents cache
        auto ccache = new ContentsCache ();
        ccache.open (ag.config.Config.get ());

        // load data from the contents index.
        // we don't show mercy to memory here, we just want the icon lookup to be fast,
        // so we have to cache the data.
        Theme[string] tmpThemes;
        auto filesPkids = ccache.getContentsMap (pkgMap.keys ());
        foreach (fname; parallel (filesPkids.byKey (), 100)) {
            if (fname.startsWith ("/usr/share/pixmaps/")) {
                auto pkg = getPackage (filesPkids[fname]);
                if (pkg is null)
                    continue;
                synchronized (this) iconFiles[fname] = pkg;
                continue;
            }

            // optimization: check if we actually have an interesting path before
            // entering the foreach loop.
            if (!fname.startsWith ("/usr/share/icons/"))
                continue;

            auto pkg = getPackage (filesPkids[fname]);
            if (pkg is null)
                continue;

            foreach (name; themeNames) {
                if (fname == format ("/usr/share/icons/%s/index.theme", name)) {
                    synchronized (this) tmpThemes[name] = new Theme (name, pkg);
                } else if (fname.startsWith (format ("/usr/share/icons/%s", name))) {
                    synchronized (this) iconFiles[fname] = pkg;
                }
            }
        }

        // when running on partial repos (e.g. PPAs) we might not have a package containing the
        // hicolor theme definition. Since we always need it to be there to properly process icons,
        // we inject our own copy here.
        if ("hicolor" !in tmpThemes) {
            logInfo ("No packaged hicolor icon theme found, using built-in one.");
            auto hicolorThemeIndex = getDataPath ("hicolor-theme-index.theme");
            if (!std.file.exists (hicolorThemeIndex)) {
                logError ("Hicolor icon theme index at '%s' was not found! We will not be able to handle icons in this theme.", hicolorThemeIndex);
            } else {
                auto f = File (hicolorThemeIndex, "r");
                string indexData;
                string ln;
                while ((ln = f.readln ()) !is null)
                    indexData ~= ln;

                tmpThemes["hicolor"] = new Theme ("hicolor", indexData);
            }
        }

        // this is necessary to keep the ordering (and therefore priority) of themes.
        // we don't know the order in which we find index.theme files in the code above,
        // therefore this sorting is necessary.
        foreach (tname; themeNames) {
            if (tname in tmpThemes)
                themes ~= tmpThemes[tname];
        }

        logDebug ("Created new IconHandler.");
    }

    private string getIconNameAndClear (Component cpt)
    {
        string name = null;

        // a not-processed icon name is stored as "1x1px" icon, so we can
        // quickly identify it here.
        auto icon = cpt.getIconBySize (1, 1);
        if (icon !is null)
            name = icon.getName ();

        // clear the list of icons in this component
        auto iconsArray = cpt.getIcons ();
        if (iconsArray.len > 0)
            iconsArray.removeRange (0, iconsArray.len);
        return name;
    }

    static private bool iconAllowed (string iconName)
    {
        foreach (ext; allowedIconExts)
            if (iconName.endsWith (ext))
                return true;
        return false;
    }

    private ImageFormat imageKindFromFile (string fname)
    {
        if (fname.endsWith (".png"))
            return ImageFormat.PNG;
        if ((fname.endsWith (".jpg")) || (fname.endsWith (".jpeg")))
            return ImageFormat.JPEG;
        if (fname.endsWith (".svg"))
            return ImageFormat.SVG;
        if (fname.endsWith (".svgz"))
            return ImageFormat.SVGZ;
        return ImageFormat.UNKNOWN;
    }

    /**
     * Generates potential filenames of the icon that is searched for in the
     * given size.
     **/
    private auto possibleIconFilenames (string iconName, ImageSize size)
    {
        auto gen = new Generator!string (
        {
            foreach (theme; this.themes) {
                foreach (fname; theme.matchingIconFilenames (iconName, size))
                    yield (fname);
            }

            // check pixmaps for icons
            foreach (extension; possibleIconExts)
                yield (format ("/usr/share/pixmaps/%s%s", iconName, extension));
        });

        return gen;
    }

    /**
     * Helper structure for the findIcons
     * method.
     **/
    private struct IconFindResult
    {
        Package pkg;
        string fname;

        this (Package pkg, string fname) {
            this.pkg = pkg;
            this.fname = fname;
        }
    }

    /**
     * Looks up 'icon' with 'size' in popular icon themes according to the XDG
     * icon theme spec.
     **/
    auto findIcons (string iconName, const ImageSize[] sizes, Package pkg = null)
    {
        IconFindResult[ImageSize] sizeMap = null;

        foreach (size; sizes) {
            foreach (fname; possibleIconFilenames (iconName, size)) {
                if (pkg !is null) {
                    // we are supposed to search in one particular package
                    if (pkg.contents.canFind (fname)) {
                        sizeMap[size] = IconFindResult (pkg, fname);
                        break;
                    }
                } else {
                    // global search in all packages
                    auto pkgP = (fname in iconFiles);
                    // continue if filename is not in map
                    if (pkgP is null)
                        continue;
                    sizeMap[size] = IconFindResult (*pkgP, fname);
                    break;
                }
            }
        }

        return sizeMap;
    }

    /**
     * Extracts the icon from the package and stores it in the cache.
     * Ensures the stored icon always has the size given in "size", and renders
     * scalable vectorgraphics if necessary.
     *
     * Params:
     *      cpt           = The component this icon belongs to.
     *      res           = The result the component belongs to.
     *      cptExportPath = The data export directory of the component.
     *      sourcePkg     = The package the to-be-extracted icon is located in.
     *      iconPath      = The (absolute) path to the icon.
     *      size          = The size the icon should be stored in.
     **/
    private bool storeIcon (Component cpt, GeneratorResult gres, string cptExportPath, Package sourcePkg, string iconPath, ImageSize size)
    {
        // don't store an icon if we are already ignoring this component
        //if cpt.has_ignore_reason():
        //    return False

        auto iformat = imageKindFromFile (iconPath);
        if (iformat == ImageFormat.UNKNOWN) {
            gres.addHint (cpt.getId (), "icon-format-unsupported", ["icon_fname": baseName (iconPath)]);
            return false;
        }

        auto path = buildPath (cptExportPath, "icons", size.toString ());
        auto iconName = format ("%s_%s", gres.pkgname,  baseName (iconPath));

        iconName = iconName.replace(".svgz", ".png");
        iconName = iconName.replace(".svg", ".png");
        auto iconStoreLocation = buildPath (path, iconName);

        if (std.file.exists (iconStoreLocation)) {
            // we already extracted that icon, skip the extraction step
            // and just add the new icon.
            auto icon = new Icon ();
            icon.setKind (IconKind.CACHED);
            icon.setWidth (size.width);
            icon.setHeight (size.height);
            icon.setName (iconName);
            cpt.addIcon (icon);
            return true;
        }

        // filepath is checked because icon can reside in another binary
        // eg amarok's icon is in amarok-data
        ubyte[] iconData = null;
        try {
            iconData = cast(ubyte[]) sourcePkg.getFileData (iconPath);
        } catch (Exception e) {
            gres.addHint(cpt.getId (), "pkg-extract-error", ["fname": baseName (iconPath), "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
            return false;
        }

        if (iconData.empty ()) {
            gres.addHint (cpt.getId (), "pkg-empty-file", ["fname": baseName (iconPath), "pkg_fname": baseName (sourcePkg.filename)]);
            return false;
        }

        // create target directory
        mkdirRecurse (path);

        if ((iformat == ImageFormat.SVG) || (iformat == ImageFormat.SVGZ)) {
            try {
                auto cv = new Canvas (size.width, size.height);
                cv.renderSvg (iconData);
                cv.savePng (iconStoreLocation);
            } catch (Exception e) {
                gres.addHint(cpt.getId (), "image-write-error", ["fname": baseName (iconPath), "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
                return false;
            }
        } else {
            Image img;
            try {
                img = new Image (iconData, iformat);
            } catch (Exception e) {
                gres.addHint(cpt.getId (), "image-write-error", ["fname": baseName (iconPath), "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
                return false;
            }

            try {
                img.scale (size.width, size.height);
                img.savePng (iconStoreLocation);
            } catch (Exception e) {
                gres.addHint(cpt.getId (), "image-write-error", ["fname": baseName (iconPath), "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
                return false;
            }
        }

        auto icon = new Icon ();
        icon.setKind (IconKind.CACHED);
        icon.setWidth (size.width);
        icon.setHeight (size.height);
        icon.setName (iconName);
        cpt.addIcon (icon);

        return true;
    }

    bool process (GeneratorResult gres, Component cpt)
    {
        auto iconName = getIconNameAndClear (cpt);
        // nothing to do if there is no icon
        if (iconName is null)
            return true;

        auto gcid = gres.gcidForComponent (cpt);
        if (gcid is null) {
            auto cid = cpt.getId ();
            if (cid is null)
                cid = "general";
            gres.addHint (cid, "internal-error", "No global ID could be found for the component.");
            return false;
        }

        auto cptMediaPath = buildPath (mediaExportPath, gcid);

        if (iconName.startsWith ("/")) {
            if (gres.pkg.contents.canFind (iconName))
                return storeIcon (cpt, gres, cptMediaPath, gres.pkg, iconName, ImageSize (64, 64));
        } else {
            iconName  = baseName (iconName);


            // Small hack: Strip .png from icon files to make the XDG and Pixmap finder
            // work properly, which add their own icon extensions and find the most suitable icon.
            if (iconName.endsWith (".png"))
                iconName = iconName[0..$-4];

            string lastIconName = null;
            /// Search for an icon in XDG icon directories.
            /// Returns true on success and sets lastIconName to the
            /// last icon name that has been handled.
            bool findAndStoreXdgIcon (Package epkg = null)
            {
                auto iconRes = findIcons (iconName, wantedIconSizes, epkg);
                if (iconRes is null)
                    return false;

                IconFindResult[ImageSize] iconsStored;
                foreach (size; wantedIconSizes) {
                    auto infoP = (size in iconRes);

                    IconFindResult info;
                    info.pkg = null;
                    if (infoP !is null)
                        info = *infoP;

                    if (info.pkg is null) {
                        // the size we want wasn't found, can we downscale a larger one?
                        foreach (asize; iconRes.byKey ()) {
                            auto data = iconRes[asize];
                            if (asize < size)
                                continue;
                            info = data;
                            break;
                        }
                    }

                    // give up if we still haven't found an icon
                    if (info.pkg is null)
                        continue;

                    lastIconName = info.fname;
                    if (iconAllowed (lastIconName)) {
                        if (storeIcon (cpt, gres, cptMediaPath, info.pkg, lastIconName, size))
                            iconsStored[size] = info;
                    } else {
                        // the found icon is not suitable, but maybe a larger one is available that we can downscale?
                        foreach (asize; iconRes.byKey ()) {
                            auto data = iconRes[asize];
                            if (asize < size)
                                continue;
                            info = data;
                            break;
                        }

                        if (iconAllowed (info.fname)) {
                            if (storeIcon (cpt, gres, cptMediaPath, info.pkg, lastIconName, size))
                                iconsStored[size] = info;
                            lastIconName = info.fname;
                        }
                    }
                }

                // ensure we have stored a 64x64px icon, since this is mandated
                // by the AppStream spec by downscaling a larger icon that we
                // might have found.
                if (ImageSize(64) !in iconsStored) {
                    foreach (size; wantedIconSizes) {
                        if (size !in iconsStored)
                            continue;
                        if (size < ImageSize(64))
                            continue;
                        auto info = iconsStored[size];
                        lastIconName = info.fname;
                        if (storeIcon (cpt, gres, cptMediaPath, info.pkg, lastIconName, ImageSize(64)))
                            return true;
                    }
                } else {
                    return true;
                }

                return false;
            }

            // search for the right icon iside the current package
            auto success = findAndStoreXdgIcon (gres.pkg);
            if ((!success) && (!gres.isIgnored (cpt))) {
                // search in all packages
                success = findAndStoreXdgIcon ();
                if (success) {
                    // we found a valid stock icon, so set that additionally to the cached one
                    auto icon = new Icon ();
                    icon.setKind (IconKind.STOCK);
                    icon.setName (iconName);
                    cpt.addIcon (icon);
                } else if ((lastIconName !is null) && (!iconAllowed (lastIconName))) {
                    gres.addHint (cpt.getId (), "icon-format-unsupported", ["icon_fname": baseName (lastIconName)]);
                }
            }

            if ((!success) && (lastIconName is null)) {
                gres.addHint (cpt.getId (), "icon-not-found", ["icon_fname": iconName]);
                return false;
            }

        }

        return true;
    }
}

unittest
{
    writeln ("TEST: ", "IconHandler");

    auto hicolorThemeIndex = getDataPath ("hicolor-theme-index.theme");
    auto f = File (hicolorThemeIndex, "r");
    string indexData;
    string ln;
    while ((ln = f.readln ()) !is null)
        indexData ~= ln;

    auto theme = new Theme ("hicolor", indexData);
    foreach (fname; theme.matchingIconFilenames ("accessories-calculator", ImageSize (48))) {
        bool valid = false;
        if (fname.startsWith ("/usr/share/icons/hicolor/48x48/"))
            valid = true;
        if (fname.startsWith ("/usr/share/icons/hicolor/scalable/"))
            valid = true;
        assert (valid);

        if ((valid) && (IconHandler.iconAllowed (fname)))
            valid = true;
        else
            valid = false;

        if (fname.endsWith (".xpm"))
            assert (!valid);
        else
            assert (valid);
    }
}
