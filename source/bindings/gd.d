/*
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 *
 * Licensed under the GNU Lesser General Public License Version 3
 *
 * This library is free software: you can redistribute it and/or modify
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
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 */

module c.gdlib;

import std.stdio;
import core.stdc.stdarg;

extern(C):
nothrow:

alias gdErrorMethod = void function (int, const(char) *, va_list);

@nogc:
static if (!is(typeof(usize))) private alias usize = size_t;

immutable gdMaxColors = 256;

alias interpolation_method = double function(double);

struct gdImage {
	/* Palette-based image pixels */
	char **pixels;
	int sx;
	int sy;
	/* These are valid in palette images only. See also
	   'alpha', which appears later in the structure to
	   preserve binary backwards compatibility */
	int colorsTotal;
	int[gdMaxColors] red;
	int[gdMaxColors] green;
	int[gdMaxColors] blue;
	int[gdMaxColors] open;
	/* For backwards compatibility, this is set to the
	   first palette entry with 100% transparency,
	   and is also set and reset by the
	   gdImageColorTransparent function. Newer
	   applications can allocate palette entries
	   with any desired level of transparency; however,
	   bear in mind that many viewers, notably
	   many web browsers, fail to implement
	   full alpha channel for PNG and provide
	   support for full opacity or transparency only. */
	int transparent;
	int *polyInts;
	int polyAllocated;
	gdImage *brush;
	gdImage *tile;
	int[gdMaxColors] brushColorMap;
	int[gdMaxColors] tileColorMap;
	int styleLength;
	int stylePos;
	int *style;
	int interlace;
	/* New in 2.0: thickness of line. Initialized to 1. */
	int thick;
	/* New in 2.0: alpha channel for palettes. Note that only
	   Macintosh Internet Explorer and (possibly) Netscape 6
	   really support multiple levels of transparency in
	   palettes, to my knowledge, as of 2/15/01. Most
	   common browsers will display 100% opaque and
	   100% transparent correctly, and do something
	   unpredictable and/or undesirable for levels
	   in between. TBB */
	int[gdMaxColors] alpha;
	/* Truecolor flag and pixels. New 2.0 fields appear here at the
	   end to minimize breakage of existing object code. */
	int trueColor;
	int **tpixels;
	/* Should alpha channel be copied, or applied, each time a
	   pixel is drawn? This applies to truecolor images only.
	   No attempt is made to alpha-blend in palette images,
	   even if semitransparent palette entries exist.
	   To do that, build your image as a truecolor image,
	   then quantize down to 8 bits. */
	int alphaBlendingFlag;
	/* Should the alpha channel of the image be saved? This affects
	   PNG at the moment; other future formats may also
	   have that capability. JPEG doesn't. */
	int saveAlphaFlag;

	/* There should NEVER BE ACCESSOR MACROS FOR ITEMS BELOW HERE, so this
	   part of the structure can be safely changed in new releases. */

	/* 2.0.12: anti-aliased globals. 2.0.26: just a few vestiges after
	  switching to the fast, memory-cheap implementation from PHP-gd. */
	int AA;
	int AA_color;
	int AA_dont_blend;

	/* 2.0.12: simple clipping rectangle. These values
	  must be checked for safety when set; please use
	  gdImageSetClip */
	int cx1;
	int cy1;
	int cx2;
	int cy2;

	/* 2.1.0: allows to specify resolution in dpi */
	uint res_x;
	uint res_y;

	/* Selects quantization method, see gdImageTrueColorToPaletteSetMethod() and gdPaletteQuantizationMethod enum. */
	int paletteQuantizationMethod;
	/* speed/quality trade-off. 1 = best quality, 10 = best speed. 0 = method-specific default.
	   Applicable to GD_QUANT_LIQ and GD_QUANT_NEUQUANT. */
	int paletteQuantizationSpeed;
	/* Image will remain true-color if conversion to palette cannot achieve given quality.
	   Value from 1 to 100, 1 = ugly, 100 = perfect. Applicable to GD_QUANT_LIQ.*/
	int paletteQuantizationMinQuality;
	/* Image will use minimum number of palette colors needed to achieve given quality. Must be higher than paletteQuantizationMinQuality
	   Value from 1 to 100, 1 = ugly, 100 = perfect. Applicable to GD_QUANT_LIQ.*/
	int paletteQuantizationMaxQuality;
	gdInterpolationMethod interpolation_id;
	interpolation_method interpolation;
};
alias gdImagePtr = gdImage*;

struct gdIOCtx {}
alias gdIOCtxPtr = gdIOCtx*;

enum gdInterpolationMethod {
	DEFAULT          = 0,
	BELL,
	BESSEL,
	BILINEAR_FIXED,
	BICUBIC,
	BICUBIC_FIXED,
	BLACKMAN,
	BOX,
	BSPLINE,
	CATMULLROM,
	GAUSSIAN,
	GENERALIZED_CUBIC,
	HERMITE,
	HAMMING,
	HANNING,
	MITCHELL,
	NEAREST_NEIGHBOUR,
	POWER,
	QUADRATIC,
	SINC,
	TRIANGLE,
	WEIGHTED4,
	METHOD_COUNT = 21
};

struct gdPoint {
	int x, y;
}
alias gdPointPtr = gdPoint*;

struct gdRect {
	int x, y;
	int width, height;
}
alias gdRectPtr = gdRect*;


// General
gdImagePtr gdImageCreateFromFile (const(char) *filename);
void gdImageDestroy (gdImagePtr im);

void gdImageInterlace (gdImagePtr im, int interlaceArg);
void gdImageAlphaBlending (gdImagePtr im, int alphaBlendingArg);
void gdImageSaveAlpha (gdImagePtr im, int saveAlphaArg);

void gdSetErrorMethod (gdErrorMethod);
void gdClearErrorMethod ();

// PNG
gdImagePtr gdImageCreateFromPng (FILE *fd);
gdImagePtr gdImageCreateFromPngCtx (gdIOCtxPtr inp);
gdImagePtr gdImageCreateFromPngPtr (int size, void *data);

// JPEG
gdImagePtr gdImageCreateFromJpeg (FILE *infile);
gdImagePtr gdImageCreateFromJpegPtr (int size, void *data);
gdImagePtr gdImageCreateFromJpegPtrEx (int size, void *data, int ignore_warning);

// GIF
gdImagePtr gdImageCreateFromGif (FILE *fd);
gdImagePtr gdImageCreateFromGifCtx (gdIOCtxPtr inp);
gdImagePtr gdImageCreateFromGifPtr (int size, void *data);

// Manipulation
int gdImageSetInterpolationMethod (gdImagePtr im, gdInterpolationMethod id);
gdInterpolationMethod gdImageGetInterpolationMethod (gdImagePtr im);

gdImagePtr gdImageCrop (gdImagePtr src, const(gdRect) *crop);
gdImagePtr gdImageCropAuto (gdImagePtr im, const uint mode);
gdImagePtr gdImageCropThreshold (gdImagePtr im, const uint color, const float threshold);
gdImagePtr gdImageScale (const gdImagePtr src, const uint new_width, const uint new_height);

// Output
void gdImagePng (gdImagePtr im, FILE *om);
void gdImagePngCtx (gdImagePtr im, gdIOCtx *oc);

void gdImageJpeg (gdImagePtr im, FILE *om, int quality);
void gdImageJpegCtx (gdImagePtr im, gdIOCtx *oc, int quality);
