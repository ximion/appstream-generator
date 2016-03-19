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

module ag.image;

import std.stdio;
import std.string;
import std.conv : to;
import std.path : baseName;
import std.math;
import cairo;
import gdlib;


enum ImageKind {
    UNKNOWN,
    PNG,
    JPEG,
    GIF,
    SVG,
    SVGZ
}

class Image
{

private:
    gdImagePtr gdi;

public:

    this (string fname)
    {
        gdi = gdImageCreateFromFile (fname.toStringz ());
        if (gdi == null)
            throw new Exception (format ("Unable to open image '%s'", baseName (fname)));
    }

    this (ImageKind ikind, string data)
    {
        import core.stdc.string : strlen;

        auto cdata = data.toStringz ();
        int cdataSize = cast(int) (char.sizeof * strlen (cdata) + 1);

        switch (ikind) {
            case ImageKind.PNG:
                gdi = gdImageCreateFromPngPtr (cdataSize, cast(void*) cdata);
                break;
            case ImageKind.JPEG:
                gdi = gdImageCreateFromJpegPtr (cdataSize, cast(void*) cdata);
                break;
            case ImageKind.GIF:
                gdi = gdImageCreateFromGifPtr (cdataSize, cast(void*) cdata);
                break;
            default:
                throw new Exception (format ("Unable to open image of type '%s'", to!string (ikind)));
        }
        if (gdi == null)
            throw new Exception ("Failed to load image data. The image might be invalid");
    }

    ~this ()
    {
        gdImageDestroy (gdi);
    }

    @property
    uint width ()
    {
        return gdi.sx;
    }

    @property
    uint height ()
    {
        return gdi.sy;
    }

    /**
     * Scale the image to the given size.
     */
    void scale (uint newWidth, uint newHeight)
    {
        gdImageSetInterpolationMethod (gdi, gdInterpolationMethod.BILINEAR_FIXED);

        auto resImg = gdImageScale (gdi, newWidth, newHeight);
        if (resImg is null)
            throw new Exception ("Scaling of image failed.");

        // set our current image to the scaled version
        gdImageDestroy (gdi);
        gdi = resImg;
    }

    /**
     * Scale the image to the given width, preserving
     * its aspect ratio.
     */
    void scaleToWidth (uint newWidth)
    {
        import std.math;

        float scaleFactor = width / newWidth;
        uint newHeight = to!uint (floor (height * scaleFactor));

        scale (newWidth, newHeight);
    }

    /**
     * Scale the image to the given height, preserving
     * its aspect ratio.
     */
    void scaleToHeight (uint newHeight)
    {
        import std.math;

        float scaleFactor = height / newHeight;
        uint newWidth = to!uint (floor (width * scaleFactor));

        scale (newWidth, newHeight);
    }

    /**
     * Scale the image to fir in a square with the given edge length,
     * and keep its aspect ratio.
     */
    void scaleToFit (uint size)
    {
        if (height > width) {
            scaleToHeight (size);
        } else {
            scaleToWidth (size);
        }
    }

    void savePng (File f)
    {
        gdImageSaveAlpha (gdi, 1);
        gdImagePng (gdi, f.getFP ());
    }
}

unittest
{
    import std.file : getcwd;
    import std.path : buildPath;
    writeln ("TEST: ", "Image");

    auto sampleImgPath = buildPath (getcwd(), "test", "samples", "appstream-logo.png");
    writeln ("Loading image");
    auto img = new Image (sampleImgPath);

    writeln ("Scaling image");
    assert (img.width == 134);
    assert (img.height == 132);
    img.scale (64, 64);
    assert (img.width == 64);
    assert (img.height == 64);

    writeln ("Storing image");
    auto f = File ("/tmp/ag-ut_test.png", "w");
    img.savePng (f);
}
