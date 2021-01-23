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

module asgen.bindings.asutils;

private import appstream.c.types;
private import glib.Str;
private import std.string : fromStringz, toStringz;
private import ascompose.c.types : ImageFormat, IssueSeverity;

extern(C) {
    private:
    nothrow:
    @nogc:
    @system:

    IssueSeverity as_issue_severity_from_string (const(char)* str) pure;
    const(char*) as_issue_severity_to_string (IssueSeverity severity) pure;

    public bool as_utils_is_tld (const(char)* tld) pure;
    public bool as_utils_is_category_name (const(char)* category_name) pure;

    public const(char*) as_format_version_to_string (FormatVersion ver) pure;
    public FormatVersion as_format_version_from_string (const(char)* version_str) pure;

    bool as_license_is_metadata_license (const(char)* license) pure;
    char** as_spdx_license_tokenize (const(char)* license) pure;

    const(char) *as_version_string () pure;

    const(char) *as_component_kind_to_string (AsComponentKind kind) pure;

    ImageFormat asc_image_format_from_filename (const(char)* fname) pure;
}

public:
@trusted:

auto severityFromString (const string str) pure
{
    return as_issue_severity_from_string (str.toStringz);
}

auto severityToString (IssueSeverity severity) pure
{
    return fromStringz (as_issue_severity_to_string (severity));
}

auto spdxLicenseTokenize (const string license) pure
{
    return Str.toStringArray (as_spdx_license_tokenize (license.toStringz));
}

bool spdxLicenseIsMetadataLicense (const string license) pure
{
    return as_license_is_metadata_license (license.toStringz);
}

auto componentKindToString (AsComponentKind kind) pure
{
    return Str.toString (as_component_kind_to_string (kind));
}

auto imageFormatFromFilename (const string fname) pure
{
    return asc_image_format_from_filename (fname.toStringz);
}

auto appstreamVersion () pure
{
    return fromStringz (as_version_string ());
}
