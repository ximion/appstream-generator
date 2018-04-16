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

module asgen.image;

import std.stdio;
import std.string;
import std.conv : to;
import std.path : baseName;
import std.math;
import core.stdc.stdarg;
import core.stdc.stdio;

import asgen.bindings.cairo;
import asgen.bindings.rsvg;
import asgen.bindings.gdkpixbuf;

import glib.c.types;
import glib.c.functions;

import asgen.logging;
import asgen.config;
import asgen.font : Font;
import core.sync.mutex;

private __gshared Mutex fontconfigMutex = null;


enum ImageFormat {
    UNKNOWN,
    PNG,
    JPEG,
    GIF,
    SVG,
    SVGZ,
    XPM
}

private void optimizePNG (string fname)
{
    import std.process;

    auto conf = asgen.config.Config.get ();
    if (!conf.featureEnabled (GeneratorFeature.OPTIPNG))
        return;

    // NOTE: Maybe add an option to run optipng with stronger optimization? (>= -o4)
    auto optipng = execute (["optipng", fname ]);
    if (optipng.status != 0)
        logWarning ("Optipng on '%s' failed with error code %s: %s", fname, optipng.status, optipng.output);
}

/**
 * Helper method required so we do not modify the Fontconfig
 * global state while reading it with another process.
 *
 * This prevents a weird deadlock when multiple threads are
 * redering stuff that contains fonts.
 **/
private void
enterFontconfigCriticalSection () @trusted
{
    if (fontconfigMutex is null)
        return;
    fontconfigMutex.lock ();
}

/**
 * Helper method required so we do not modify the Fontconfig
 * global state while reading it with another process.
 *
 * This prevents a weird deadlock when multiple threads are
 * redering stuff that contains fonts.
 **/
private void
leaveFontconfigCriticalSection () @trusted
{
    if (fontconfigMutex is null)
        return;
    fontconfigMutex.unlock ();
}

public void
setupFontconfigMutex () @trusted
{
    fontconfigMutex = new Mutex;
}

final class Image
{

private:
    GdkPixbuf pix;

public:

    private void throwGError (GError *error, string pretext = null)
    {
        if (error !is null) {
            auto msg = fromStringz (error.message).dup;
            g_error_free (error);

            if (pretext is null)
                throw new Exception (to!string (msg));
            else
                throw new Exception (format ("%s: %s", pretext, to!string (msg)));
        }
    }

    this (string fname)
    {
        GError *error = null;
        pix = gdk_pixbuf_new_from_file (fname.toStringz (), &error);
        throwGError (error, format ("Unable to open image '%s'", baseName (fname)));
    }

    this (ref ubyte[] imgBytes, ImageFormat ikind)
    {
        import gio.c.functions;
        import gio.MemoryInputStream;

        auto istream = new MemoryInputStream ();
        istream.addData (imgBytes, null);

        GError *error = null;
        pix = gdk_pixbuf_new_from_stream (cast(GInputStream*) istream.getMemoryInputStreamStruct (), null, &error);
        throwGError (error, "Failed to load image data");
    }

    ~this ()
    {
        if (pix !is null)
            g_object_unref (pix);
    }

    @property
    uint width ()
    {
        return pix.gdk_pixbuf_get_width ();
    }

    @property
    uint height ()
    {
        return pix.gdk_pixbuf_get_height ();
    }

    /**
     * Scale the image to the given size.
     */
    void scale (uint newWidth, uint newHeight)
    {
        auto resPix = gdk_pixbuf_scale_simple (pix, newWidth, newHeight, GdkInterpType.BILINEAR);
        if (resPix is null)
            throw new Exception (format ("Scaling of image to %sx%s failed.", newWidth, newHeight));

        // set our current image to the scaled version
        g_object_unref (pix);
        pix = resPix;
    }

    /**
     * Scale the image to the given width, preserving
     * its aspect ratio.
     */
    void scaleToWidth (uint newWidth)
    {
        float scaleFactor = cast(float) newWidth / cast (float) width;
        uint newHeight = to!uint (floor (height * scaleFactor));

        scale (newWidth, newHeight);
    }

    /**
     * Scale the image to the given height, preserving
     * its aspect ratio.
     */
    void scaleToHeight (uint newHeight)
    {
        float scaleFactor = cast(float) newHeight / cast(float) height;
        immutable newWidth = to!uint (floor (width * scaleFactor));

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

    void savePng (string fname)
    {
        GError *error = null;
        gdk_pixbuf_save (pix, fname.toStringz (), "png", &error, null);
        throwGError (error);

        optimizePNG (fname);
    }
}

final class Canvas
{

private:
    cairo_surface_p srf;
    cairo_p cr;

    int width_;
    int height_;

public:

    this (int w, int h)
    {
         srf = cairo_image_surface_create (cairo_format_t.FORMAT_ARGB32, w, h);
         cr = cairo_create (srf);

         width_ = w;
         height_ = h;
    }

    ~this ()
    {
        if (cr !is null)
            cairo_destroy (cr);
        if (srf !is null)
            cairo_surface_destroy (srf);
    }

    @property
    uint width ()
    {
        return width_;
        //! return srf.cairo_image_surface_get_width ();
    }

    @property
    uint height ()
    {
        return height_;
        //! return srf.cairo_image_surface_get_height ();
    }

    void renderSvg (ref ubyte[] svgBytes)
    {
        // NOTE: unfortunately, Cairo/RSvg uses Fontconfig internally, so
        // we need to lock this down since a parallel-processed font
        // might need to access this too.
        // This can likely be optimized by checking whether it's really
        // a Font that is holding the lock (= make only fonts increase the
        // Mutex counter)
        enterFontconfigCriticalSection ();

        auto handle = rsvg_handle_new ();
        scope (exit) {
            g_object_unref (handle);
            leaveFontconfigCriticalSection ();
        }

        auto svgBSize = ubyte.sizeof * svgBytes.length;
        GError *error = null;
        rsvg_handle_write (handle, cast(ubyte*) svgBytes, svgBSize, &error);
        if (error !is null) {
            auto msg = fromStringz (error.message).dup;
            g_error_free (error);
            throw new Exception (to!string (msg));
        }

        rsvg_handle_close (handle, &error);
        if (error !is null) {
            auto msg = fromStringz (error.message).dup;
            g_error_free (error);
            throw new Exception (to!string (msg));
        }

        RsvgDimensionData dims;
        rsvg_handle_get_dimensions (handle, &dims);

        auto w = cast(double) cairo_image_surface_get_width (srf);
        auto h = cast(double) cairo_image_surface_get_height (srf);

        // cairo_translate (cr, (w - dims.width) / 2, (h - dims.height) / 2);
        cairo_scale (cr, w / dims.width, h / dims.height);

        cr.cairo_save ();
        scope (exit) cr.cairo_restore ();
        if (!rsvg_handle_render_cairo (handle, cr))
            throw new Exception ("Rendering of SVG images failed!");
    }

    /**
     * Draw a simple line of text without linebreaks to fill the canvas.
     **/
    void drawTextLine (const ref Font font, string text, uint borderWidth = 4)
    {
        import asgen.bindings.freetype : FT_LOAD_DEFAULT;
        enterFontconfigCriticalSection ();
        scope (exit) leaveFontconfigCriticalSection ();

        auto cff = cairo_ft_font_face_create_for_ft_face (font.fontFace, FT_LOAD_DEFAULT);
        scope (exit) cairo_font_face_destroy (cff);

        // set font face for Cairo surface
        auto status = cairo_font_face_status (cff);
        if (status != cairo_status_t.STATUS_SUCCESS)
            throw new Exception ("Could not set font face for Cairo: %s".format (to!string (status)));
        cairo_set_font_face (cr, cff);

        cairo_text_extents_t te;
        uint textSize = 128;
        while (textSize-- > 0) {
            cairo_set_font_size (cr, textSize);
            cairo_text_extents (cr, text.toStringz, &te);
            if (te.width <= 0.01f || te.height <= 0.01f)
                continue;
            if (te.width < this.width - (borderWidth * 2) &&
                te.height < this.height - (borderWidth * 2))
			    break;
	    }

        // draw text
    	cairo_move_to (cr,
    		       (this.width / 2) - te.width / 2 - te.x_bearing,
    		       (this.height / 2) - te.height / 2 - te.y_bearing);
    	cairo_set_source_rgb (cr, 0.0, 0.0, 0.0);
    	cairo_show_text (cr, text.toStringz);

        cairo_save (cr);
    }

    /**
     * Draw a longer text with linebreaks.
     */
    void drawText (const ref Font font, string text, const uint borderWidth = 4, const uint linePad = 2)
    {
        import asgen.bindings.freetype : FT_LOAD_DEFAULT;
        enterFontconfigCriticalSection ();
        scope (exit) leaveFontconfigCriticalSection ();

        auto cff = cairo_ft_font_face_create_for_ft_face (font.fontFace, FT_LOAD_DEFAULT);
        scope (exit) cairo_font_face_destroy (cff);

        // set font face for Cairo surface
        auto status = cairo_font_face_status (cff);
        if (status != cairo_status_t.STATUS_SUCCESS)
            throw new Exception (format ("Could not set font face for Cairo: %s", to!string (status)));
        cairo_set_font_face (cr, cff);

        // calculate best font size
        uint linePadding = linePad;
        auto lines = text.split ("\n");
        string longestLine;
        if (lines.length <= 1) {
            linePadding = 0;
            longestLine = text;
        } else {
            ulong ll = 0;
            longestLine = lines[0];
            foreach (line; lines) {
                if (line.length > ll)
                    longestLine = line;
                    ll = line.length;
            }
        }

        cairo_text_extents_t te;
        uint text_size = 128;
        while (text_size-- > 0) {
            cairo_set_font_size (cr, text_size);
            cairo_text_extents (cr, longestLine.toStringz, &te);
            if (te.width <= 0.01f || te.height <= 0.01f)
                continue;
            if (te.width < this.width - (borderWidth * 2) &&
                (te.height * lines.length + linePadding) < this.height - (borderWidth * 2))
			    break;
	    }

        // center text and draw it
        auto xPos = (this.width / 2) - te.width / 2 - te.x_bearing;
        auto teHeight = te.height * lines.length + linePadding * (lines.length.to!long - 1);
        auto yPos = (teHeight / 2) - teHeight / 2 - te.y_bearing + borderWidth;
        cairo_move_to (cr, xPos, yPos);
        cairo_set_source_rgb (cr, 0.0, 0.0, 0.0);

        foreach (line; lines) {
            cairo_show_text (cr, line.toStringz ());
            yPos += te.height + linePadding;
            cairo_move_to (cr, xPos, yPos);
        }
        cairo_save (cr);
    }

    void savePng (string fname)
    {
        auto status = cairo_surface_write_to_png (srf, fname.toStringz ());
        if (status != cairo_status_t.STATUS_SUCCESS)
            throw new Exception (format ("Could not save canvas to PNG: %s", to!string (status)));

        optimizePNG (fname);
    }
}

unittest
{
    import std.file : getcwd;
    import std.path : buildPath;
    import asgen.utils : getTestSamplesDir;
    writeln ("TEST: ", "Image");

    auto sampleImgPath = buildPath (getTestSamplesDir (), "appstream-logo.png");
    writeln ("Loading image (file)");
    auto img = new Image (sampleImgPath);

    writeln ("Scaling image");
    assert (img.width == 134);
    assert (img.height == 132);
    img.scale (64, 64);
    assert (img.width == 64);
    assert (img.height == 64);

    writeln ("Storing image");
    img.savePng ("/tmp/ag-iscale_test.png");

    writeln ("Loading image (data)");
    ubyte[] data;
    auto f = File (sampleImgPath, "r");
    while (!f.eof) {
        char[300] buf;
        data ~= f.rawRead (buf);
    }

    img = new Image (data, ImageFormat.PNG);
    writeln ("Scaling image (data)");
    img.scale (124, 124);
    writeln ("Storing image (data)");
    img.savePng ("/tmp/ag-iscale-d_test.png");

    writeln ("Rendering SVG");
    auto sampleSvgPath = buildPath (getTestSamplesDir (), "table.svgz");
    data = null;
    f = File (sampleSvgPath, "r");
    while (!f.eof) {
        char[300] buf;
        data ~= f.rawRead (buf);
    }
    auto cv = new Canvas (512, 512);
    cv.renderSvg (data);
    writeln ("Saving rendered PNG");
    cv.savePng ("/tmp/ag-svgrender_test1.png");

    writeln ("Font rendering");
    auto font = new Font (buildPath (getTestSamplesDir (), "NotoSans-Regular.ttf"));

    cv = new Canvas (400, 100);
    cv.drawText (font,
                  "Hello World!\nSecond Line!\nThird line - äöüß!\nA very, very, very long line.");
    cv.savePng ("/tmp/ag-fontrender_test1.png");
}
