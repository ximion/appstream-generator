/*
 * Copyright (C) 2016-2020 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.handlers.screenshothandler;

import std.path : baseName, buildPath;
import std.uni : toLower;
import std.string : format, strip;
import std.array : empty;
import std.algorithm : startsWith;
import std.conv : to;
import gobject.ObjectG : ObjectG;
import gobject.c.functions : g_object_ref;
import appstream.Component : Component;
import appstream.Screenshot : AsScreenshot, Screenshot, ScreenshotMediaKind;
import appstream.Image : AsImage, Image, ImageKind;
import appstream.Video : AsVideo, Video, VideoContainerKind, VideoCodecKind;
import appstream_compose.c.types : ImageFormat, ImageLoadFlags, ImageSaveFlags;
static import appstream_compose.Image;
static import std.file;

import asgen.config : Config;
import asgen.result : GeneratorResult;
import asgen.downloader : Downloader;
import asgen.utils : ImageSize, filenameFromURI, getFileContents;
import asgen.logging;


private immutable screenshotSizes = [ImageSize (1248, 702), ImageSize (752, 423), ImageSize (624, 351), ImageSize (224, 126)];

void processScreenshots (GeneratorResult gres, Component cpt, string mediaExportDir)
{
    auto scrArr = cpt.getScreenshots ();
    if (scrArr.len == 0)
        return;

    auto gcid = gres.gcidForComponent (cpt);
    if (gcid is null) {
        gres.addHint (cpt, "internal-error", "No global ID could be found for the component.");
        return;
    }
    immutable scrExportDir = buildPath (mediaExportDir, gcid, "screenshots");
    immutable scrBaseUrl = buildPath (gcid, "screenshots");

    Screenshot[] validScrs;
    for (uint i = 0; i < scrArr.len; i++) {
        // cast array data to D Screenshot and keep a reference to the C struct
        auto scr = new Screenshot (cast (AsScreenshot*) g_object_ref (scrArr.index (i)), true);
        immutable mediaKind = scr.getMediaKind;

        Screenshot resScr;
        if (mediaKind == ScreenshotMediaKind.VIDEO)
            resScr = processScreenshotVideos (gres,
                                              cpt,
                                              scr,
                                              scrExportDir,
                                              scrBaseUrl,
                                              i + 1);
        else
            resScr = processScreenshotImages (gres,
                                              cpt,
                                              scr,
                                              scrExportDir,
                                              scrBaseUrl,
                                              i + 1);

        if (resScr !is null)
            validScrs ~= resScr;
    }

    // drop all screenshots from the component
    scrArr.removeRange (0, scrArr.len);

    // add valid screenshots back
    foreach (ref scr; validScrs)
        cpt.addScreenshot (scr);
}

/**
 * Contains some basic information about the video
 * we downloaded from an upstream site.
 */
private struct VideoInfo
{
    string codecName;
    string audioCodecName;
    int width;
    int height;
    string formatName;
    VideoContainerKind containerKind;
    VideoCodecKind codecKind;
    bool isAcceptable;
}

private VideoInfo checkVideoInfo (GeneratorResult gres, Component cpt, const Config conf, const string vidFname)
{
    import glib.Spawn : Spawn, SpawnFlags;
    import std.array : split;
    import std.string : indexOf;
    import std.algorithm : canFind, endsWith;

    VideoInfo vinfo;

    int exitStatus;
    string ffStdout;
    string ffStderr;

    try {
        // NOTE: We are currently extracting information from ffprobe's simple output, but it also has a JSON
        // mode. Parsing JSON is a bit slower, but if it is more reliable we should switch to that.
        Spawn.sync (null, // working directory
                    [conf.ffprobeBinary,
                     "-v", "quiet",
                     "-show_entries", "stream=width,height,codec_name,codec_type",
                     "-show_entries", "format=format_name",
                     "-of", "default=noprint_wrappers=1",
                      vidFname],
                    [], // envp
                    SpawnFlags.LEAVE_DESCRIPTORS_OPEN,
                    null, // child setup
                    null, // user data
                    ffStdout, // out stdout
                    ffStderr, // out stderr
                    exitStatus);
    } catch (Exception e) {
        logError ("Failed to spawn ffprobe: %s", e.to!string);
        gres.addHint (cpt, "metainfo-screenshot-but-no-media", ["fname": vidFname.baseName, "msg": e.to!string]);
        return vinfo;
    }

    if (exitStatus != 0) {
        if (!ffStdout.empty) {
            if (ffStderr.empty)
                ffStderr = ffStdout;
            else
                ffStderr = ffStderr ~ "\n" ~ ffStdout;
        }
        logWarning ("FFprobe on '%s' failed with error code %s: %s", vidFname, exitStatus, ffStderr);
        gres.addHint (cpt, "metainfo-screenshot-but-no-media", ["fname": vidFname.baseName, "msg": "Code %s, %s".format (exitStatus, ffStderr)]);
        return vinfo;
    }

    string prevCodecName;
    foreach (immutable entry; ffStdout.split ("\n")) {
        immutable sPos = entry.indexOf ('=');
        if (sPos <= 0)
            continue;
        immutable value = entry[sPos+1..$];
        switch (entry[0..sPos]) {
            case "codec_name":
                prevCodecName = value;
                break;
            case "codec_type":
                if (value == "video") {
                    if (vinfo.codecName.empty)
                        vinfo.codecName = prevCodecName;
                } else if (value == "audio") {
                    if (vinfo.audioCodecName.empty)
                        vinfo.audioCodecName = prevCodecName;
                }
                break;
            case "format_name":
                if (vinfo.formatName.empty)
                    vinfo.formatName = value;
                break;
            case "width":
                if (value != "N/A")
                    vinfo.width = value.to!int;
                break;
            case "height":
                if (value != "N/A")
                    vinfo.height = value.to!int;
                break;
            default:
                break;
        }
    }

    // Check whether the video container is a supported format
    // Since WebM is a subset of Matroska, FFmpeg lists them as one thing
    // and us distinguishing by file extension here is a bit artificial.
    if (vinfo.formatName.canFind ("webm")) {
        if (vidFname.endsWith (".webm"))
            vinfo.containerKind = VideoContainerKind.WEBM;
    }
    if (vinfo.formatName.canFind ("matroska"))
        vinfo.containerKind = VideoContainerKind.MKV;

    // Check codec
    if (vinfo.codecName == "av1")
        vinfo.codecKind = VideoCodecKind.AV1;
    else if (vinfo.codecName == "vp9")
        vinfo.codecKind = VideoCodecKind.VP9;

    // Check audio
    auto audioOkay = true;
    if (!vinfo.audioCodecName.empty) {
        // this video has an audio track... meh.
        gres.addHint (cpt, "screenshot-video-has-audio", ["fname": vidFname.baseName]);
        if (vinfo.audioCodecName != "opus") {
            gres.addHint (cpt, "screenshot-video-audio-codec-unsupported", ["fname": vidFname.baseName,
                                                                            "codec": vinfo.audioCodecName]);
            audioOkay = false;
        }
    }

    // A video file may contain multiple streams, so this check isn't extensive, but it protects against 99% of cases where
    // people were using unsupported formats.
    vinfo.isAcceptable = (vinfo.containerKind != VideoContainerKind.UNKNOWN) && (vinfo.codecKind != VideoCodecKind.UNKNOWN) && (audioOkay);
    if (!vinfo.isAcceptable) {
        gres.addHint (cpt, "screenshot-video-format-unsupported", ["fname": vidFname.baseName,
                                                                   "codec": vinfo.codecName,
                                                                   "container": vinfo.formatName]);
    }

    return vinfo;
}

private Screenshot processScreenshotVideos (GeneratorResult gres, Component cpt, Screenshot scr, const string scrExportDir, const string scrBaseUrl, uint scrNo)
{
    auto vidArr = scr.getVideos ();
    if (vidArr.len == 0) {
        gres.addHint (cpt, "metainfo-screenshot-but-no-media");
        return null;
    }

    auto conf = Config.get;
    auto downloader = Downloader.get;

    // ignore this screenshot if we aren't permitted to have video screencasts
    if (!conf.feature.screenshotVideos)
        return null;
    immutable maxVidSize = conf.maxVideoFileSize;

    // ensure export dir exists
    std.file.mkdirRecurse (scrExportDir);

    Video[] validVideos;
    for (uint i = 0; i < vidArr.len; i++) {
        auto vid = new Video (cast (AsVideo*) g_object_ref (vidArr.index (i)), true);

        immutable origVidUrl = vid.getUrl;
        if (origVidUrl.empty)
            continue;

        immutable scrVidName = "vid%s-%s_%s".format (scrNo, i, filenameFromURI (origVidUrl));
        immutable scrVidPath = buildPath (scrExportDir, scrVidName);
        immutable srcVidUrl =  buildPath (scrBaseUrl, scrVidName);

        try {
            downloader.downloadFile (origVidUrl, scrVidPath);
        } catch (Exception e) {
            gres.addHint (cpt, "screenshot-download-error", ["url": origVidUrl, "error": e.msg]);
            return null;
        }

        immutable vinfo = checkVideoInfo (gres, cpt, conf, scrVidPath);
        if (!vinfo.isAcceptable)
            continue; // we already marked the screenshot to be ignored at this point

        immutable vidSizeMiB = std.file.getSize (scrVidPath) / 1024 / 1024;
        if ((maxVidSize > 0) && (vidSizeMiB > maxVidSize)) {
            gres.addHint (cpt, "screenshot-video-too-big", ["fname": scrVidName,
                                                            "max_size": "%s MiB".format (maxVidSize),
                                                            "size": "%s MiB".format (vidSizeMiB)]);
            continue;
        }

        vid.setCodecKind (vinfo.codecKind);
        vid.setContainerKind (vinfo.containerKind);
        vid.setHeight (vinfo.height);
        vid.setWidth (vinfo.width);
        vid.setUrl (srcVidUrl);

        // if we should not create a screenshots store, delete the just-downloaded file and set
        // the original upstream URL as source.
        // we still needed to download the video to get information about its size.
        if (!conf.feature.storeScreenshots)
            vid.setUrl (origVidUrl);

        validVideos ~= vid;
    }

    // if we don't store screenshots, the export dir is only a temporary cache
    if (!conf.feature.storeScreenshots)
        std.file.rmdirRecurse (scrExportDir);

    // if we have no valid videos, ignore the screenshot
    if (validVideos.empty)
        return null;

    // drop all videos
    vidArr.removeRange (0, vidArr.len);

    // add the valid ones back
    foreach (ref vid; validVideos)
        scr.addVideo (vid);

    return scr;
}

private Screenshot processScreenshotImages (GeneratorResult gres, Component cpt, Screenshot scr, const string scrExportDir, const string scrBaseUrl, uint scrNo)
{
    auto imgArr = scr.getImages ();
    if (imgArr.len == 0) {
        gres.addHint (cpt, "metainfo-screenshot-but-no-media");
        return null;
    }

    auto origImg = new Image (cast(AsImage*) g_object_ref (imgArr.index (0)), true);
    // drop all images
    imgArr.removeRange (0, imgArr.len);

    auto conf = Config.get ();
    immutable origImgUrl = origImg.getUrl.strip ();
    immutable origImageLocale = origImg.getLocale;

    if (origImgUrl.empty)
        return null;

    ubyte[] imgData;
    try {
        imgData = getFileContents (origImgUrl);
    } catch (Exception e) {
        gres.addHint (cpt, "screenshot-download-error", ["url": origImgUrl, "error": e.msg]);
        return null;
    }

    immutable gcid = gres.gcidForComponent (cpt);
    if (gcid is null) {
        gres.addHint (cpt, "internal-error", "No global ID could be found for the component.");
        return null;
    }

    // ensure export dir exists
    std.file.mkdirRecurse (scrExportDir);

    uint sourceScrWidth;
    uint sourceScrHeight;
    try {
        immutable srcImgName = format ("image-%s_orig.png", scrNo);
        immutable srcImgPath = buildPath (scrExportDir, srcImgName);
        immutable srcImgUrl =  buildPath (scrBaseUrl, srcImgName);

        // save the source screenshot as PNG image
        auto srcImg = new appstream_compose.Image.Image (imgData.ptr, cast(ptrdiff_t)imgData.length,
                                                         0, ImageLoadFlags.NONE);
        srcImg.saveFilename (srcImgPath,
                             0, 0,
                             ImageSaveFlags.OPTIMIZE);

        auto img = new Image ();
        img.setKind (ImageKind.SOURCE);
        img.setLocale (origImageLocale);

        sourceScrWidth = srcImg.getWidth;
        sourceScrHeight = srcImg.getHeight;
        img.setWidth (sourceScrWidth);
        img.setHeight (sourceScrHeight);

        // if we should not create a screenshots store, delete the just-downloaded file and set
        // the original upstream URL as source.
        // we still needed to download the screenshot to get information about its size.
        if (!conf.feature.storeScreenshots) {
            img.setUrl (origImgUrl);
            scr.addImage (img);

            // drop screenshot storage directory, in this mode it is only ever used temporarily
            std.file.rmdirRecurse (scrExportDir);
            return scr;
        }

        img.setUrl (srcImgUrl);
        scr.addImage (img);
    } catch (Exception e) {
        gres.addHint (cpt.getId (), "screenshot-save-error", ["url": origImgUrl, "error": format ("Can not store source screenshot: %s", e.msg)]);
        return null;
    }

    // generate & save thumbnails for the screenshot image
    bool thumbnailsGenerated = false;
    foreach (size; screenshotSizes) {
        // ensure we will only downscale the screenshot for thumbnailing
        if (size.width > sourceScrWidth)
            continue;
        if (size.height > sourceScrHeight)
            continue;

        try {
            auto thumb = new appstream_compose.Image.Image (imgData.ptr, cast(ptrdiff_t)imgData.length,
                                                            0, ImageLoadFlags.NONE);
            if (size.width > size.height)
                thumb.scaleToWidth (size.width);
            else
                thumb.scaleToHeight (size.height);

            // create thumbnail storage path and URL component
            auto thumbImgName = "image-%s_%sx%s.png".format (scrNo, thumb.getWidth, thumb.getHeight);
            auto thumbImgPath = buildPath (scrExportDir, thumbImgName);
            auto thumbImgUrl =  buildPath (scrBaseUrl, thumbImgName);

            // store the thumbnail image on disk
            thumb.saveFilename(thumbImgPath,
                               0, 0,
                               ImageSaveFlags.OPTIMIZE);

            // finally prepare the thumbnail definition and add it to the metadata
            auto img = new Image ();
            img.setLocale (origImageLocale);
            img.setKind (ImageKind.THUMBNAIL);
            img.setWidth (thumb.getWidth);
            img.setHeight (thumb.getHeight);
            img.setUrl (thumbImgUrl);
            scr.addImage (img);
        } catch (Exception e) {
            gres.addHint (cpt.getId (), "screenshot-save-error", ["url": origImgUrl, "error": format ("Failure while preparing thumbnail: %s", e.msg)]);
            return null;
        }

        thumbnailsGenerated = true;
    }

    if (!thumbnailsGenerated)
        gres.addHint (cpt.getId (), "screenshot-no-thumbnails", ["url": origImgUrl]);

    return scr;
}

unittest {
    import std.stdio : writeln;
    import asgen.utils : getTestSamplesDir;
    import asgen.backends.dummy.dummypkg : DummyPackage;
    import appstream.Component : ComponentKind;

    writeln ("TEST: ", "ScreenshotHandler");
    auto conf = Config.get;

    auto pkg = new DummyPackage ("foobar", "1.0", "amd64");
    auto gres = new GeneratorResult (pkg);
    auto cpt = new Component;
    cpt.setKind (ComponentKind.GENERIC);
    cpt.setId ("org.example.Test");

    if (conf.ffprobeBinary.empty) {
        // Fedora doesn't have FFmpeg in its repositories, so we don't fail tests here.
        // appstream-generator is useful without FFmpeg.
        logWarning ("Skipped video metadata tests due to missing `ffprobe` binary.");
    } else {
        immutable sampleVidFname = buildPath (getTestSamplesDir, "sample-video.mkv");
        auto vinfo = checkVideoInfo (gres, cpt, conf, sampleVidFname);
        assert (vinfo.width == 640);
        assert (vinfo.height == 360);
        assert (vinfo.codecKind == VideoCodecKind.AV1);
        assert (vinfo.containerKind == VideoContainerKind.MKV);
        assert (vinfo.isAcceptable);
        assert (gres.hintsCount == 0);
    }
}
