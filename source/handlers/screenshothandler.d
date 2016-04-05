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

module ag.handlers.screenshothandler;

import std.path : baseName, buildPath;
import std.uni : toLower;
import std.string : format;
import std.stdio;
import gobject.ObjectG;
import gi.appstream;
import appstream.Component;
import appstream.Screenshot;
import appstream.Image;

import ag.result;
import ag.utils;


private immutable screenshotSizes = [ImageSize (1248, 702), ImageSize (752, 423), ImageSize (624, 351), ImageSize (224, 126)];

void processScreenshots (GeneratorResult gres, Component cpt, string mediaExportDir)
{
    auto scrArr = cpt.getScreenshots ();
    if (scrArr.len == 0)
        return;

    Screenshot[] validScrs;
    for (uint i = 0; i < scrArr.len; i++) {
        // cast array data to D Screenshot and keep a reference to the C struct
        auto scr = new Screenshot (cast (AsScreenshot*) scrArr.index (i));
        auto resScr = processScreenshot (gres, cpt, scr, mediaExportDir, i+1);
        if (resScr !is null) {
            validScrs ~= resScr;
            resScr.doref ();
        }
    }

    // drop all screenshots from the component
    scrArr.removeRange (0, scrArr.len);

    // add valid screenshots back
    foreach (scr; validScrs) {
        cpt.addScreenshot (scr);
    }
}

private Screenshot processScreenshot (GeneratorResult gres, Component cpt, Screenshot scr, string mediaExportDir, uint scrNo)
{
    import std.stdio;

    auto imgArr = scr.getImages ();
    if (imgArr.len == 0) {
        gres.addHint (cpt.getId (), "metainfo-screenshot-but-no-image");
        return null;
    }

    auto initImg = new Image (cast(AsImage*) imgArr.index (0));
    initImg.doref ();
    // drop all images
    imgArr.removeRange (0, imgArr.len);

    auto imgUrl = initImg.getUrl ();

    ubyte[] imgData;
    try {
        import std.net.curl;
        imgData = get! (AutoProtocol, ubyte) (imgUrl);
    } catch (Exception e) {
        gres.addHint (cpt.getId (), "screenshot-download-error", ["url": imgUrl, "error": e.msg]);
        return null;
    }

    auto gcid = gres.gcidForComponent (cpt);
    if (gcid is null) {
        auto cid = cpt.getId ();
        if (cid is null)
            cid = "general";
        gres.addHint (cid, "internal-error", "No global ID could be found for the component.");
        return null;
    }

    auto cptScreenshotsPath = buildPath (mediaExportDir, gcid, "screenshots");
    auto cptScreenshotsUrl = buildPath (gcid, "screenshots");
    std.file.mkdirRecurse (cptScreenshotsPath);

    try {
        auto srcImgName = format ("image-%s_orig.png", scrNo);
        auto srcImgPath = buildPath (cptScreenshotsPath, srcImgName);
        auto srcImgUrl =  buildPath (cptScreenshotsUrl, srcImgName);

        // save the source screenshot as PNG image
        auto srcImg = new ag.image.Image (imgData, ag.image.ImageFormat.PNG);
        srcImg.savePng (srcImgPath);

        auto img = new Image ();
        img.setKind (ImageKind.SOURCE);
        img.setWidth (srcImg.width);
        img.setHeight (srcImg.height);
        img.setUrl (srcImgUrl);
        scr.addImage (img);
    } catch (Exception e) {
        gres.addHint (cpt.getId (), "screenshot-save-error", ["url": imgUrl, "error": format ("Can not store source screenshot: %s", e.msg)]);
        return null;
    }

    // generate & save thumbnails for the screenshot image
    foreach (size; screenshotSizes) {
        auto thumbImgName = format ("image-%s_%s.png", scrNo, size.toString ());
        auto thumbImgPath = buildPath (cptScreenshotsPath, thumbImgName);
        auto thumbImgUrl =  buildPath (cptScreenshotsUrl, thumbImgName);

        try {
            auto thumb = new ag.image.Image (imgData, ag.image.ImageFormat.PNG);
            if (size.width > size.height)
                thumb.scaleToWidth (size.width);
            else
                thumb.scaleToHeight (size.height);

            thumb.savePng (thumbImgPath);

            // finally prepare the thumbnail definition and add it to the metadata
            auto img = new Image ();
            img.setKind (ImageKind.THUMBNAIL);
            img.setWidth (thumb.width);
            img.setHeight (thumb.height);
            img.setUrl (thumbImgUrl);
            scr.addImage (img);
        } catch (Exception e) {
            gres.addHint (cpt.getId (), "screenshot-save-error", ["url": imgUrl, "error": format ("Failure while preparing thumbnail: %s", e.msg)]);
            return null;
        }
    }

    return scr;
}
