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

module asgen.bindings.appstream_utils;

import appstream.c.types;

extern(C):
nothrow:
@nogc:
@system:

bool as_utils_is_tld (const char *tld) pure;
bool as_utils_is_category_name (const char *category_name) pure;

const(char) *as_format_version_to_string (FormatVersion ver) pure;
FormatVersion as_format_version_from_string (const char *version_str) pure;

bool as_license_is_metadata_license (const char *license) pure;
