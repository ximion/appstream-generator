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
import appstream.Component;
import appstream.Icon;

import ag.result;
import ag.utils;
import ag.image;
import ag.backend.intf;


immutable possibleIconExts = [".png", ".jpg", ".svgz", ".svg", ".gif", ".ico", ".xpm"];
immutable allowedIconExts  = [".png", ".jpg", ".svgz", ".svg"];

struct IconSize
{
    uint width;
    uint height;

    this (uint w, uint h)
    {
        width = w;
        height = h;
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

class IconHandler
{

private:
    string mediaExportPath;

public:

    this (string mediaPath)
    {
        mediaExportPath = mediaPath;
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
