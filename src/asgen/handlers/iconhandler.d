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

module asgen.handlers.iconhandler;

import std.stdio : File, writeln;
import std.string : endsWith, startsWith, format;
import std.array : replace, array, empty;
import std.path : baseName, buildPath;
import std.uni : toLower;
import std.file : mkdirRecurse;
import std.algorithm : canFind, map;
import std.variant : Algebraic;
import std.typecons : scoped;
import std.parallelism : parallel;
import std.concurrency : Generator, yield;
import containers : HashMap;
import glib.KeyFile;
import appstream.Component;
import appstream.Icon;
static import std.file;

import asgen.utils;
import asgen.logging;
import asgen.result;
import asgen.image;
import asgen.backends.interfaces;
import asgen.contentsstore;
import asgen.config : Config, IconPolicy, GeneratorFeature;


// all image extensions that we recognize as possible for icons.
// the most favorable file extension needs to come first to prefer it
private immutable possibleIconExts = [".png", ".jpg", ".svgz", ".svg", ".gif", ".ico", ".xpm"];

// the image extensions that we will actually allow software to have.
private immutable allowedIconExts  = [".png", ".jpg", ".svgz", ".svg", ".xpm"];

/**
 * Describes an icon theme as specified in the XDG theme spec.
 */
private final class Theme
{

private:
    string name;
    Algebraic!(int, string)[string][] directories;

public:

    this (const string name, const(ubyte)[] indexData)
    {
        this.name = name;

        auto index = new KeyFile ();
        auto indexText = cast(string) indexData;
        index.loadFromData (indexText, -1, GKeyFileFlags.NONE);

        size_t dummy;
        foreach (section; index.getGroups (dummy)) {
            string type;
            string context;
            int scale;
            int threshold;
            int size;
            int minSize;
            int maxSize;

            // we ignore symbolic icons
            if (section.startsWith("symbolic/"))
                continue;

            try {
                size = index.getInteger (section, "Size");
                context = index.getString (section, "Context");
            } catch (Throwable) {
                continue;
            }

            try {
                threshold = index.getInteger (section, "Threshold");
            } catch (Throwable) {
                threshold = 2;
            }
            try {
                type = index.getString (section, "Type");
            } catch (Throwable) {
                type = "Threshold";
            }
            try {
                minSize = index.getInteger (section, "MinSize");
            } catch (Throwable) {
                minSize = size;
            }
            try {
                maxSize = index.getInteger (section, "MaxSize");
            } catch (Throwable) {
                maxSize = size;
            }
            try {
                scale = index.getInteger (section, "Scale");
            } catch (Throwable) {
                scale = 1;
            }

            if (size == 0)
                continue;
            auto themedir = [
                "path": Algebraic!(int, string) (section),
                "type": Algebraic!(int, string) (type),
                "size": Algebraic!(int, string) (size),
                "minsize": Algebraic!(int, string) (minSize),
                "maxsize": Algebraic!(int, string) (maxSize),
                "threshold": Algebraic!(int, string) (threshold),
                "scale": Algebraic!(int, string) (scale)
            ];
            directories ~= themedir;
        }

        // sort our directory list, so the smallest size is at the top
        import std.algorithm : sort;
        directories.sort!("a[\"size\"].get!int < b[\"size\"].get!int");
    }

    this (const string name, Package pkg)
    {
        auto indexData = pkg.getFileData (buildPath ("/usr/share/icons", name, "index.theme"));
        this (name, indexData);
    }

    /**
     * Check if a directory is suitable for the selected size.
     * If @assumeThresholdScalable is set to true, we will allow
     * downscaling of any higher-than-requested icon size, even if the
     * section is of "Threshold" type and would usually prohibit the scaling.
     */
    private bool directoryMatchesSize (Algebraic!(int, string)[string] themedir, ImageSize size, bool assumeThresholdScalable = false)
    {
        immutable scale = themedir["scale"].get!int;
        if (scale != size.scale)
            return false;
        immutable type = themedir["type"].get!string;
        if (type == "Fixed")
            return size.toInt () == themedir["size"].get!int;
        if (type == "Scalable") {
            if ((themedir["minsize"].get!int <= size.toInt) && (size.toInt <= themedir["maxsize"].get!int))
                return true;
            return false;
        }
        if (type == "Threshold") {
            immutable themeSize = themedir["size"].get!int;
            immutable th = themedir["threshold"].get!int;

            if (assumeThresholdScalable) {
                // we treat this "Threshold" as if we were allowed to downscale its icons if they
                // have a higher size.
                // This can lead to "wrong" scaling, but allows us to retrieve more icons.
                return themeSize >= size.toInt;
            } else {
                // follow the proper algorithm as defined by the XDG spec
                if (((themeSize - th) <= size.toInt) && (size.toInt <= (themeSize + th)))
                    return true;
            }

            return false;
        }

        return false;
    }

    /**
     * Returns an iteratable of possible icon filenames that match @iname and @size.
     * If @relaxedScalingRules is set to true, we scale down any bigger icon seize, even
     * if the theme definition would usually prohibit that.
     **/
    auto matchingIconFilenames (string iname, ImageSize size, bool relaxedScalingRules = false)
    {
        auto gen = new Generator!string (
        {
            foreach (themedir; this.directories) {
                if (directoryMatchesSize (themedir, size, relaxedScalingRules)) {
                    // best filetype needs to come first to be preferred, only types allowed by the spec are handled at all
                    foreach (extension; ["png", "svgz", "svg", "xpm"])
                        yield ("/usr/share/icons/%s/%s/%s.%s".format (this.name, themedir["path"].get!(string), iname, extension));
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
final class IconHandler
{

private:
    string mediaExportPath;

    Theme[] themes;
    HashMap!(string, Package) iconFiles;
    string[] themeNames;

    IconPolicy[] iconPolicy;
    IconPolicy defaultIconPolicy;

    bool allowIconUpscaling;

public:

    this (string mediaPath, IconPolicy[] iconPolicy, HashMap!(string, Package) pkgMap, string iconTheme = null)
    {
        logDebug ("Creating new IconHandler");

        iconFiles = HashMap!(string, Package) (32);
        mediaExportPath = mediaPath;
        this.iconPolicy = iconPolicy;

        foreach (ref policy; iconPolicy) {
            if (policy.iconSize == ImageSize (64)) {
                defaultIconPolicy = policy;
                break;
            }
        }

        // Sanity checks
        if (defaultIconPolicy.iconSize != ImageSize (64))
            throw new Exception ("Could not find default icon site '64x64' in icon policy list. This is a bug in the generator or configuration file.");
        assert (defaultIconPolicy.storeCached == true);

        auto conf = Config.get;
        allowIconUpscaling = conf.featureEnabled (GeneratorFeature.ALLOW_ICON_UPSCALE);

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
        themeNames ~= "Adwaita";  // GNOME
        themeNames ~= "breeze";   // KDE

        Package getPackage (string pkid)
        {
            if (pkid is null)
                return null;
            return pkgMap.get (pkid, null);
        }

        // open package contents cache
        auto ccache = scoped!ContentsStore ();
        ccache.open (conf);

        // load data from the contents index.
        // we don't show mercy to memory here, we just want the icon lookup to be fast,
        // so we have to cache the data.
        auto tmpThemes = HashMap!(string, Theme) (16);
        auto filesPkids = ccache.getIconFilesMap (pkgMap.keys);
        foreach (fname; parallel (filesPkids.byKey, 100)) {
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
                if (fname == "/usr/share/icons/%s/index.theme".format (name)) {
                    synchronized (this) tmpThemes[name] = new Theme (name, pkg);
                } else if (fname.startsWith ("/usr/share/icons/%s".format (name))) {
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
                ubyte[] indexData;
                auto f = File (hicolorThemeIndex, "r");
                while (!f.eof) {
                    char[GENERIC_BUFFER_SIZE] buf;
                    indexData ~= f.rawRead (buf);
                }

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
        auto icon = componentGetStockIcon (cpt);
        if (!icon.isNull)
            name = icon.get.getName ();

        // clear the list of icons in this component
        auto iconsArray = cpt.getIcons ();
        if (iconsArray.len > 0)
            iconsArray.removeRange (0, iconsArray.len);
        return name;
    }

    static private bool iconAllowed (string iconName)
    {
        foreach (ref ext; allowedIconExts)
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
        if (fname.endsWith (".xpm"))
            return ImageFormat.XPM;
        return ImageFormat.UNKNOWN;
    }

    /**
     * Generates potential filenames of the icon that is searched for in the
     * given size.
     **/
    private auto possibleIconFilenames (string iconName, ImageSize size, bool relaxedScalingRules = false)
    {
        auto gen = new Generator!string (
        {
            foreach (theme; this.themes) {
                foreach (fname; theme.matchingIconFilenames (iconName, size, relaxedScalingRules))
                    yield (fname);
            }

            // check pixmaps directory for icons
            // we only ever use the pixmap directory contents to satisfy the minimum 64x64px icon
            // requirement. Otherwise we get weird upscaling to higher sizes or HiDPI sizes happening,
            // as later code tries to downscale "bigger" sizes.
            if (size.scale == 1 && size.width == 64) {
                foreach (extension; possibleIconExts)
                    yield ("/usr/share/pixmaps/%s%s".format (iconName, extension));
            }
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
    private auto findIcons (string iconName, const ImageSize[] sizes, Package pkg = null)
    {
        auto sizeMap = HashMap!(ImageSize, IconFindResult) (16);

        foreach (size; sizes) {
            // search for possible icon filenames, using relaxed scaling rules by default
            foreach (fname; possibleIconFilenames (iconName, size, true)) {
                if (pkg !is null) {
                    // we are supposed to search in one particular package
                    if (pkg.contents.canFind (fname)) {
                        sizeMap[size] = IconFindResult (pkg, fname);
                        break;
                    }
                } else {
                    // global search in all packages
                    auto pkg = iconFiles.get (fname, null);
                    // continue if filename is not in map
                    if (pkg is null)
                        continue;
                    sizeMap[size] = IconFindResult (pkg, fname);
                    break;
                }
            }
        }

        return sizeMap;
    }

    /**
     * Strip file extension from icon.
     */
    string stripIconExt (ref string iconName)
    {
        if (iconName.endsWith (".png"))
            return iconName[0..$-4];
        if (iconName.endsWith (".svg"))
            return iconName[0..$-4];
        if (iconName.endsWith (".xpm"))
            return iconName[0..$-4];
        if (iconName.endsWith (".svgz"))
            return iconName[0..$-5];
        return iconName;
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
    private bool storeIcon (Component cpt,
                            GeneratorResult gres,
                            string cptExportPath,
                            Package sourcePkg,
                            string iconPath,
                            IconPolicy policy)
    {
        immutable size = policy.iconSize;
        auto iformat = imageKindFromFile (iconPath);
        if (iformat == ImageFormat.UNKNOWN) {
            gres.addHint (cpt.getId (), "icon-format-unsupported", ["icon_fname": baseName (iconPath)]);
            return false;
        }

        auto path = buildPath (cptExportPath, "icons", size.toString);
        auto iconName = "%s_%s".format (gres.pkgname,  baseName (iconPath));

        if (iconName.endsWith (".svgz"))
            iconName = iconName.replace (".svgz", ".png");
        else if (iconName.endsWith (".svg"))
            iconName = iconName.replace (".svg", ".png");
        else if (iconName.endsWith (".xpm"))
            iconName = iconName.replace (".xpm", ".png");
        auto iconStoreLocation = buildPath (path, iconName);

        if (std.file.exists (iconStoreLocation)) {
            // we already extracted that icon, skip the extraction step
            // and just add the new icon.

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
                    gres.addHint (cpt, "internal-error", "No global ID could be found for the component, could not add remote icon.");
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

        auto scaled_width = size.width * size.scale;
        auto scaled_height = size.height * size.scale;
        if ((iformat == ImageFormat.SVG) || (iformat == ImageFormat.SVGZ)) {
            // create target directory
            mkdirRecurse (path);

            try {
                auto cv = scoped!Canvas (scaled_width, scaled_height);
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

            if (iformat == ImageFormat.XPM) {
                // we use XPM images only if they are large enough
                if (allowIconUpscaling) {
                    // we only try upscaling for the default 64x64px size and only if
                    // the icon is not too small
                    if (size != ImageSize (64))
                        return false;
                    if ((img.width < 48) || (img.height < 48))
                        return false;
                } else {
                    if ((img.width < scaled_width) || (img.height < scaled_height))
                        return false;
                }
            }

            // ensure that we don't try to make an application visible that has a really tiny icon
            // by upscaling it to a blurry mess
            if (size.scale == 1 && size.width == 64) {
                if ((img.width < 48) || (img.height < 48)) {
                    gres.addHint (cpt, "icon-too-small", ["icon_name": iconName,
                                                          "icon_size": "%ux%u".format (img.width, img.height)]);
                    return false;
                }
            }

            // warn about icon upscaling, it looks ugly
            if (scaled_width > img.width) {
                gres.addHint (cpt, "icon-scaled-up", ["icon_name": iconName,
                                                      "icon_size": "%ux%u".format (img.width, img.height),
                                                      "scale_size": size.toString]);
            }

            // create target directory
            mkdirRecurse (path);

            try {
                img.scale (scaled_width, scaled_height);
                img.savePng (iconStoreLocation);
            } catch (Exception e) {
                gres.addHint (cpt, "image-write-error", ["fname": baseName (iconPath),
                                                         "pkg_fname": baseName (sourcePkg.filename),
                                                         "error": e.msg]);
                return false;
            }
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
                gres.addHint (cpt, "internal-error", "No global ID could be found for the component, could not add remote icon.");
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

        return true;
    }

    /**
     * Helper function to try to find an icon that we can up- or downscale to the desired size.
     */
    private auto findIconScalableToSize (ref HashMap!(ImageSize, IconFindResult) possibleIcons, const ref ImageSize size)
    {
        IconFindResult info;
        info.pkg = null;

        // on principle, never attempt to up- or downscale an icon to something below
        // AppStream's default icon size.
        // The clients can do that just as well, without us wasting disk space
        // and network bandwidth.
        if (size.scale == 1 && size.width < 64)
            return info;

        // the size we want wasn't found, can we downscale a larger one?
        foreach (ref asize; possibleIcons.byKey) {
            auto data = possibleIcons[asize];
            if (asize.scale != size.scale)
                continue;
            if (asize < size)
                continue;
            info = data;
            break;
        }

        if ((info.pkg is null) && (allowIconUpscaling) && (size == defaultIconPolicy.iconSize)) {
            // no icon was found to downscale, but we allow upscaling, so try one last time
            // to find a suitable icon for at least the default AppStream icon size.

            foreach (ref asize; possibleIcons.byKey) {
                auto data = possibleIcons[asize];
                // we never allow icons smaller than 48x48px
                if (asize.width < 48)
                    continue;
                if (asize.scale != size.scale)
                    continue;
                info = data;
                break;
            }
        }

        return info;
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

        logDebug ("Looking for icon '%s' for '%s::%s'", iconName, gres.pkid, cpt.getId);
        auto cptMediaPath = buildPath (mediaExportPath, gcid);

        if (iconName.startsWith ("/")) {
            if (gres.pkg.contents.canFind (iconName))
                return storeIcon (cpt, gres, cptMediaPath, gres.pkg, iconName, defaultIconPolicy);
        } else {
            iconName  = baseName (iconName);

            // Small hack: Strip .png and other extensions from icon files to make the XDG and Pixmap finder
            // work properly, which add their own icon extensions and find the most suitable icon.
            iconName = stripIconExt (iconName);

            string lastIconName = null;
            /// Search for an icon in XDG icon directories.
            /// Returns true on success and sets lastIconName to the
            /// last icon name that has been handled.
            bool findAndStoreXdgIcon (Package epkg = null)
            {
                auto iconRes = findIcons (iconName, array(iconPolicy.map!(a => a.iconSize)), epkg);
                if (iconRes.empty)
                    return false;

                auto iconsStored = HashMap!(ImageSize, IconFindResult) (8);
                foreach (ref policy; iconPolicy) {
                    immutable size = policy.iconSize;
                    auto infoP = (size in iconRes);

                    IconFindResult info;
                    info.pkg = null;
                    if (infoP !is null)
                        info = *infoP;

                    // check if we can scale another size to the desired one
                    if (info.pkg is null)
                        info = findIconScalableToSize (iconRes, size);

                    // give up if we still haven't found an icon
                    if (info.pkg is null)
                        continue;

                    lastIconName = info.fname;
                    if (iconAllowed (lastIconName)) {
                        if (storeIcon (cpt, gres, cptMediaPath, info.pkg, lastIconName, policy))
                            iconsStored[size] = info;
                    } else {
                        // the found icon is not suitable, but maybe we can scale a differently sized icon to the right one?
                        info = findIconScalableToSize (iconRes, size);
                        if (info.pkg is null)
                            continue;

                        if (iconAllowed (info.fname)) {
                            if (storeIcon (cpt, gres, cptMediaPath, info.pkg, lastIconName, policy))
                                iconsStored[size] = info;
                            lastIconName = info.fname;
                        }
                    }
                }

                // ensure we have stored a 64x64px icon, since this is mandated
                // by the AppStream spec by downscaling a larger icon that we
                // might have found.
                if (ImageSize(64) !in iconsStored) {
                    foreach (size; iconPolicy.map!(a => a.iconSize)) {
                        if (size !in iconsStored)
                            continue;
                        if (size < ImageSize(64))
                            continue;
                        auto info = iconsStored[size];
                        lastIconName = info.fname;
                        if (storeIcon (cpt, gres, cptMediaPath, info.pkg, lastIconName, defaultIconPolicy))
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
    ubyte[] indexData;
    auto f = File (hicolorThemeIndex, "r");
    while (!f.eof) {
        char[GENERIC_BUFFER_SIZE] buf;
        indexData ~= f.rawRead (buf);
    }

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

        if (fname.endsWith (".ico"))
            assert (!valid);
        else
            assert (valid);
    }

    foreach (fname; theme.matchingIconFilenames ("accessories-text-editor", ImageSize (192))) {
        if (fname.startsWith ("/usr/share/icons/hicolor/192x192/"))
            continue;
        if (fname.startsWith ("/usr/share/icons/hicolor/256x256/"))
            continue;
        if (fname.startsWith ("/usr/share/icons/hicolor/512x512/"))
            continue;
        if (fname.startsWith ("/usr/share/icons/hicolor/scalable/"))
            continue;
        assert (0);
    }
}
