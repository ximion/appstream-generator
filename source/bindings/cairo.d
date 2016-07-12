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

module c.cairo;

extern(C):
nothrow:
@nogc:
static if (!is(typeof(usize))) private alias usize = size_t;

struct _cairo {}
alias cairo_p = _cairo*;

struct _cairo_surface {}
alias cairo_surface_p = _cairo_surface*;

struct _cairo_font_face {}
alias cairo_font_face_p = _cairo_font_face*;

struct cairo_text_extents_t {
    double x_bearing;
    double y_bearing;
    double width;
    double height;
    double x_advance;
    double y_advance;
};

enum cairo_status_t {
    STATUS_SUCCESS = 0,

    STATUS_NO_MEMORY,
    STATUS_INVALID_RESTORE,
    STATUS_INVALID_POP_GROUP,
    STATUS_NO_CURRENT_POINT,
    STATUS_INVALID_MATRIX,
    STATUS_INVALID_STATUS,
    STATUS_NULL_POINTER,
    STATUS_INVALID_STRING,
    STATUS_INVALID_PATH_DATA,
    STATUS_READ_ERROR,
    STATUS_WRITE_ERROR,
    STATUS_SURFACE_FINISHED,
    STATUS_SURFACE_TYPE_MISMATCH,
    STATUS_PATTERN_TYPE_MISMATCH,
    STATUS_INVALID_CONTENT,
    STATUS_INVALID_FORMAT,
    STATUS_INVALID_VISUAL,
    STATUS_FILE_NOT_FOUND,
    STATUS_INVALID_DASH,
    STATUS_INVALID_DSC_COMMENT,
    STATUS_INVALID_INDEX,
    STATUS_CLIP_NOT_REPRESENTABLE,
    STATUS_TEMP_FILE_ERROR,
    STATUS_INVALID_STRIDE,
    STATUS_FONT_TYPE_MISMATCH,
    STATUS_USER_FONT_IMMUTABLE,
    STATUS_USER_FONT_ERROR,
    STATUS_NEGATIVE_COUNT,
    STATUS_INVALID_CLUSTERS,
    STATUS_INVALID_SLANT,
    STATUS_INVALID_WEIGHT,
    STATUS_INVALID_SIZE,
    STATUS_USER_FONT_NOT_IMPLEMENTED,
    STATUS_DEVICE_TYPE_MISMATCH,
    STATUS_DEVICE_ERROR,
    STATUS_INVALID_MESH_CONSTRUCTION,
    STATUS_DEVICE_FINISHED,
    STATUS_JBIG2_GLOBAL_MISSING,

    STATUS_LAST_STATUS
};

enum cairo_format_t {
    FORMAT_INVALID   = -1,
    FORMAT_ARGB32    = 0,
    FORMAT_RGB24     = 1,
    FORMAT_A8        = 2,
    FORMAT_A1        = 3,
    FORMAT_RGB16_565 = 4,
    FORMAT_RGB30     = 5
};

// Context
cairo_p cairo_create (cairo_surface_p target);
cairo_p cairo_reference (cairo_p cr);
void cairo_destroy (cairo_p cr);
void cairo_set_source_surface (cairo_p cr, cairo_surface_p surface, double x, double y);
void cairo_paint (cairo_p cr);

void cairo_save (cairo_p cr);
void cairo_restore (cairo_p cr);


// Surface
cairo_surface_p cairo_image_surface_create (cairo_format_t format, int width, int height);
cairo_surface_p cairo_image_surface_create_from_png (const(char) *filename); // Toy API
void cairo_surface_destroy (cairo_surface_p surface);
cairo_status_t cairo_surface_status (cairo_surface_p surface);
int cairo_image_surface_get_width (cairo_surface_p surface);
int cairo_image_surface_get_height (cairo_surface_p surface);
cairo_status_t cairo_surface_write_to_png (cairo_surface_p surface, const(char) *filename); // Toy API

void cairo_surface_flush (cairo_surface_p surface);
ubyte* cairo_image_surface_get_data (cairo_surface_p surface);

// Transformations
void cairo_scale (cairo_p cr, double sx, double sy);
void cairo_translate (cairo_p cr, double tx, double ty);

// Drawing
void cairo_move_to (cairo_p cr, double x, double y);
void cairo_set_source_rgb (cairo_p cr, double red, double green, double blue);

// Fonts
import c.freetype;
cairo_font_face_p cairo_ft_font_face_create_for_ft_face (FT_Face face, int load_flags);
void cairo_font_face_destroy (cairo_font_face_p font_face);
cairo_status_t cairo_font_face_status (cairo_font_face_p font_face);

cairo_font_face_p cairo_get_font_face (cairo_p cr);
void cairo_set_font_face (cairo_p cr, cairo_font_face_p font_face);

void cairo_set_font_size (cairo_p cr, double size);
void cairo_show_text (cairo_p cr, const(char) *utf8); // Toy API

void cairo_text_extents (cairo_p cr, const(char) *utf8, cairo_text_extents_t *extents);
