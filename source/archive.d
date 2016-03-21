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

module ag.archive;

import std.stdio;
import std.string;
import std.file;
import std.regex;
import c.libarchive;

immutable DEFAULT_BLOCK_SIZE = 65536;

private string readArchiveData (archive *ar, string name = null)
{
    archive_entry *ae;
    immutable BUFFER_SIZE = 8192;
    int ret;
    size_t size;
    string data;
    char[BUFFER_SIZE] buff;

    ret = archive_read_next_header (ar, &ae);
    if (ret != ARCHIVE_OK) {
        if (name is null)
            throw new Exception (format ("Unable to read header of compressed data."));
        else
            throw new Exception (format ("Unable to read header of compressed file '%s'", name));
    }

    while (true) {
        size = archive_read_data (ar, cast(void*) buff, BUFFER_SIZE);
        if (size < 0) {
            if (name is null)
                throw new Exception (format ("Failed to read compressed data."));
            else
                throw new Exception (format ("Failed to read data from '%s'", name));
        }

        if (size == 0)
            break;

        data ~= buff[0..size];
    }

    return data;
}

string decompressFile (string fname)
{
    int ret;

    archive *ar = archive_read_new ();
    scope(exit) archive_read_free (ar);

    archive_read_support_compression_all (ar);
    archive_read_support_format_raw (ar);

    ret = archive_read_open_filename (ar, toStringz (fname), 16384);
    if (ret != ARCHIVE_OK)
        throw new Exception (format ("Unable to open compressed file '%s'", fname));

    return readArchiveData (ar, fname);
}

string decompressData (ubyte[] data)
{
    int ret;

    archive *ar = archive_read_new ();
    scope(exit) archive_read_free (ar);

    archive_read_support_compression_all (ar);
    archive_read_support_format_raw (ar);

    auto dSize = ubyte.sizeof * data.length;
    ret = archive_read_open_memory (ar, cast(void*) data, dSize);
    if (ret != ARCHIVE_OK)
        throw new Exception (format ("Unable to open compressed data."));

    return readArchiveData (ar);
}

class CompressedArchive
{

private:
    string archive_fname;

    string readEntry (archive *ar)
    {
        const void *buff = null;
        size_t size = 0UL;
        long offset = 0;
        string res;

        while (archive_read_data_block (ar, &buff, &size, &offset) == ARCHIVE_OK) {
            res ~= cast(string) buff[0..size];
        }

        return res;
	}

    void extractEntryTo (archive *ar, string fname)
    {
        const void *buff = null;
        size_t size = 0UL;
        long offset = 0;
        long output_offset = 0;

        auto f = File (fname, "w"); // open for writing

        while (archive_read_data_block (ar, &buff, &size, &offset) == ARCHIVE_OK) {
            if (offset > output_offset) {
                f.seek (offset - output_offset, SEEK_CUR);
                output_offset = offset;
            }
            while (size > 0) {
                auto bytes_to_write = size;
                if (bytes_to_write > DEFAULT_BLOCK_SIZE)
                    bytes_to_write = DEFAULT_BLOCK_SIZE;

                    try {
                        f.rawWrite (buff[0..bytes_to_write]);
                    } catch (Exception e) {
                        throw e;
                    }

                output_offset += bytes_to_write;
                size -= bytes_to_write;
            }
        }
    }

    archive *openArchive ()
    {
        archive *ar = archive_read_new ();

        archive_read_support_compression_all (ar);
        archive_read_support_format_all (ar);

        auto ret = archive_read_open_filename (ar, archive_fname.toStringz (), DEFAULT_BLOCK_SIZE);
        if (ret != ARCHIVE_OK)
            throw new Exception (format ("Unable to open compressed file '%s'", archive_fname));

        return ar;
    }

public:

    this ()
    {
    }

    void open (string fname)
    {
        archive_fname = fname;
    }

    bool extractFileTo (string fname, string fdest)
    {
        archive *ar;
        archive_entry *en;

        try {
            ar = openArchive ();
        } catch (Exception e) {
            throw e;
        }
        scope(exit) archive_read_free (ar);

        while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
            auto pathname = fromStringz (archive_entry_pathname (en));

            if (pathname == fname) {
                this.extractEntryTo (ar, fdest);
                return true;
		    } else {
                archive_read_data_skip (ar);
            }
        }

        return false;
    }

    string readData (string fname)
    {
        archive *ar;
        archive_entry *en;

        try {
            ar = openArchive ();
        } catch (Exception e) {
            throw e;
        }
        scope(exit) archive_read_free (ar);

        if (!fname.startsWith ("."))
            fname = "."~fname;

        while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
            auto pathname = fromStringz (archive_entry_pathname (en));

            if (pathname == fname) {
                return this.readEntry (ar);
		    } else {
                archive_read_data_skip (ar);
            }
        }

        return null;
    }

    string[] extractFilesByRegex (Regex!char re, string destdir)
    {
        import std.path;
        archive *ar;
        archive_entry *en;
        string[] matches;

        try {
            ar = openArchive ();
        } catch (Exception e) {
            throw e;
        }
        scope(exit) archive_read_free (ar);

        while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
            auto pathname = fromStringz (archive_entry_pathname (en));

            auto m = matchFirst (pathname, re);
            if (!m.empty) {
                auto fdest = buildPath (destdir, baseName (pathname));
                this.extractEntryTo (ar, fdest);
                matches ~= fdest;
		    } else {
                archive_read_data_skip (ar);
            }
        }

        return matches;
    }

    string[] readContents ()
    {
        import std.conv : to;
        archive *ar;
        archive_entry *en;

        try {
            ar = openArchive ();
        } catch (Exception e) {
            throw e;
        }
        scope (exit) archive_read_free (ar);

        string[] contents;
        while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
            auto pathname = fromStringz (archive_entry_pathname (en));

            // ignore directories
            if (pathname.endsWith ("/"))
                continue;

            if (pathname.startsWith ("."))
                pathname = pathname[1..$];
            contents ~= to!string (pathname);
        }

        return contents;
    }
}
