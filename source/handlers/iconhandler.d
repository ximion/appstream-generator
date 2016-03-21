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
import glib.KeyFile;
import appstream.Component;
import appstream.Icon;

import ag.utils;
import ag.logging;
import ag.result;
import ag.image;
import ag.backend.intf;
import ag.std.concurrency.generator;


private immutable possibleIconExts = [".png", ".jpg", ".svgz", ".svg", ".gif", ".ico", ".xpm"];
private immutable allowedIconExts  = [".png", ".jpg", ".svgz", ".svg"];

private immutable wantedSizes  = [IconSize (64), IconSize (128)];


struct IconSize
{
    uint width;
    uint height;

    this (uint w, uint h)
    {
        width = w;
        height = h;
    }

    this (uint s)
    {
        width = s;
        height = s;
    }

    string toString ()
    {
        return format ("%sx%s", width, height);
    }

    uint toInt ()
    {
        if (width > height)
            return width;
        return height;
    }
}

/**
 * Describes an icon theme as specified in the XDG theme spec.
 */
private class Theme
{

private:
    string name;
    Algebraic!(int, string)[string][] directories;

public:

    this (string name, Package pkg)
    {
        this.name = name;

        auto indexData = pkg.getFileData (buildPath ("/usr/share/icons", name, "index.theme"));

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

    private bool directoryMatchesSize (Algebraic!(int, string)[string] themedir, IconSize size)
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
    auto matchingIconFilenames (string iname, IconSize size)
    {
        auto gen = new Generator!string (
        {
            foreach (themedir; this.directories) {
                if (directoryMatchesSize (themedir, size)) {
                    // best filetype needs to come first to be preferred, only types allowed by the spec are handled at all
                    foreach (extension; ["png", "svgz", "svg", "xpm"])
                        yield (format ("usr/share/icons/%s/%s/%s.%s", this.name, themedir["path"].get!(string), iname, extension));
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

    this (string mediaPath, ContentsIndex cindex, string iconTheme = null)
    {
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

        // load data from the contents index.
        // we don't show mercy to memory here, we just want the icon lookup to be fast,
        // so we have to cache the data.
        foreach (fname; cindex.files) {
            if (fname.startsWith ("/usr/share/pixmaps/")) {
                iconFiles[fname] = cindex.packageForFile (fname);
                continue;
            }

            // optimization: check if we actually have an interesting path before
            // entering the foreach loop.
            if (!fname.startsWith ("/usr/share/icons/"))
                continue;

            foreach (name; themeNames) {
                auto pkg = cindex.packageForFile (fname);
                if (fname == format ("/usr/share/icons/%s/index.theme", name)) {
                    themes ~= new Theme (name, pkg);
                } else if (fname.startsWith (format ("/usr/share/icons/%s", name))) {
                    iconFiles[fname] = pkg;
                }
            }
        }

        debugmsg ("Created new IconHandler.");
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
        return ImageFormat.Unknown;
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
    private bool storeIcon (Component cpt, GeneratorResult gres, string cptExportPath, Package sourcePkg, string iconPath, IconSize size)
    {
        // don't store an icon if we are already ignoring this component
        //if cpt.has_ignore_reason():
        //    return False

        auto iformat = imageKindFromFile (iconPath);
        if (iformat == ImageFormat.Unknown) {
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
        string iconData = null;
        try {
            iconData = sourcePkg.getFileData (iconPath);
        } catch (Exception e) {
            gres.addHint(cpt.getId (), "pkg-extract-error", ["fname": iconName, "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
            return false;
        }

        if (iconData.empty ()) {
            gres.addHint (cpt.getId (), "pkg-extract-error", ["fname": iconName, "pkg_fname": baseName (sourcePkg.filename),
                                    "error": "Icon data was empty. The icon might be a symbolic link pointing at a file outside of this package. "
                                        "Please do not do that and instead place the icons in their appropriate directories in <code>/usr/share/icons/hicolor/</code>."]);
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
                gres.addHint(cpt.getId (), "image-write-error", ["fname": iconName, "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
                return false;
            }
        } else {
            Image img;
            try {
                img = new Image (iconData, iformat);
            } catch (Exception e) {
                gres.addHint(cpt.getId (), "icon-load-error", ["fname": iconName, "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
                return false;
            }

            try {
                img.scale (size.width, size.height);

                auto f = File (iconStoreLocation, "w");
                img.savePng (f);
            } catch (Exception e) {
                gres.addHint(cpt.getId (), "image-write-error", ["fname": iconName, "pkg_fname": baseName (sourcePkg.filename), "error": e.msg]);
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

    private bool processComponent (Component cpt, GeneratorResult gres)
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
            gres.addHint (cid, "internal-error", "No global ID could be found for the component. This is a bug.");
            return false;
        }

        auto cptMediaPath = buildPath (mediaExportPath, gcid);

        if (iconName.startsWith ("/")) {
            if (gres.pkg.getContentsList ().canFind (iconName))
                return storeIcon (cpt, gres, cptMediaPath, gres.pkg, iconName, IconSize (64, 64));
        } else {
            writeln (iconName);
        }

        return true;
    }

    void process (GeneratorResult res)
    {
        foreach (cpt; res.getComponents ()) {
            processComponent (cpt, res);
        }
    }
}

unittest
{
    import ag.backend.debian.debpackage;
    writeln ("TEST: ", "IconHandler");

    //auto pkg = new DebPackage ("foobar", "1.0", "amd64");
    //pkg.filename = "/srv/debmirror/tanglu/pool/main/a/adwaita-icon-theme/adwaita-icon-theme_3.16.0-0tanglu1_all.deb";

    //auto theme = new Theme ("Adwaita", pkg);
    //foreach (fname; theme.matchingIconFilenames ("accessories-calculator", IconSize (48)))
    //    writeln (fname);
}
