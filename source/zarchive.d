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

import std.stdio;
import std.string;
import std.regex;
import std.conv : to;
import std.path : buildNormalizedPath;
import std.array : appender;
static import std.file;
import logging;

version (GNU)
	import bindings.concurrency_generator;
else
	import std.concurrency : Generator, yield;

version (unittest) {
    version (GNU) {
        extern(C) char *mkdtemp (char *) nothrow @nogc;
    } else {
        import core.sys.posix.stdlib : mkdtemp;
    }
}

import bindings.libarchive;

private immutable DEFAULT_BLOCK_SIZE = 65536;

enum ArchiveType
{
    GZIP,
    XZ
}

private const(char)[] getArchiveErrorMessage (archive *ar)
{
    return fromStringz (archive_error_string (ar));
}

private string readArchiveData (archive *ar, string name = null)
{
    archive_entry *ae;
    int ret;
    size_t size;
    char[GENERIC_BUFFER_SIZE] buff;
    auto data = appender!string;

    ret = archive_read_next_header (ar, &ae);

    if (ret == ARCHIVE_EOF)
        return data.data;

    if (ret != ARCHIVE_OK) {
        if (name is null)
            throw new Exception (format ("Unable to read header of compressed data: %s", getArchiveErrorMessage (ar)));
        else
            throw new Exception (format ("Unable to read header of compressed file '%s': %s", name, getArchiveErrorMessage (ar)));
    }

    while (true) {
        size = archive_read_data (ar, cast(void*) buff, GENERIC_BUFFER_SIZE);
        if (size < 0) {
            if (name is null)
                throw new Exception (format ("Failed to read compressed data: %s", getArchiveErrorMessage (ar)));
            else
                throw new Exception (format ("Failed to read data from '%s': %s", name, getArchiveErrorMessage (ar)));
        }

        if (size == 0)
            break;

        data ~= buff[0..size];
    }

    return data.data;
}

string decompressFile (string fname)
{
    int ret;

    archive *ar = archive_read_new ();
    scope(exit) archive_read_free (ar);

    archive_read_support_format_raw (ar);
    archive_read_support_format_empty (ar);
    archive_read_support_filter_all (ar);

    ret = archive_read_open_filename (ar, toStringz (fname), DEFAULT_BLOCK_SIZE);
    if (ret != ARCHIVE_OK)
        throw new Exception (format ("Unable to open compressed file '%s': %s", fname, getArchiveErrorMessage (ar)));

    return readArchiveData (ar, fname);
}

string decompressData (ubyte[] data)
{
    int ret;

    archive *ar = archive_read_new ();
    scope(exit) archive_read_free (ar);

    archive_read_support_filter_all (ar);
    archive_read_support_format_empty (ar);
    archive_read_support_format_raw (ar);

    auto dSize = ubyte.sizeof * data.length;
    ret = archive_read_open_memory (ar, cast(void*) data, dSize);
    if (ret != ARCHIVE_OK)
        throw new Exception (format ("Unable to open compressed data: %s", getArchiveErrorMessage (ar)));

    return readArchiveData (ar);
}

class ArchiveDecompressor
{

private:
    string archive_fname;

    const(ubyte)[] readEntry (archive *ar)
    {
        const void *buff = null;
        size_t size = 0UL;
        long offset = 0;
        auto res = appender!(ubyte[]);

        while (archive_read_data_block (ar, &buff, &size, &offset) == ARCHIVE_OK) {
            res ~= cast(ubyte[]) buff[0..size];
        }

        return res.data;
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

        archive_read_support_filter_all (ar);
        archive_read_support_format_all (ar);

        auto ret = archive_read_open_filename (ar, archive_fname.toStringz (), DEFAULT_BLOCK_SIZE);
        if (ret != ARCHIVE_OK)
            throw new Exception (format ("Unable to open compressed file '%s': %s",
                                 archive_fname,
                                 getArchiveErrorMessage (ar)));

        return ar;
    }

    bool pathMatches (string path1, string path2) {
        import std.path;

        if (path1 == path2)
            return true;

        auto path1Abs = buildNormalizedPath ("/", path1);
        auto path2Abs = buildNormalizedPath ("/", path2);

        if (path1Abs == path2Abs)
            return true;

        return false;
    }

public:

    struct ArchiveEntry
    {
        string fname;
        const(ubyte)[] data;
    }

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

            if (pathMatches (fname, to!string (pathname))) {
                this.extractEntryTo (ar, fdest);
                return true;
		    } else {
                archive_read_data_skip (ar);
            }
        }

        return false;
    }

    void extractArchive (const string dest)
    in { assert (std.file.isDir (dest)); }
    body
    {
        import std.path;
        archive *ar;
        archive_entry *en;

        ar = openArchive ();
        scope(exit) archive_read_free (ar);

        while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
            auto pathname = buildPath (dest, archive_entry_pathname (en).fromStringz);
            /* at the moment we only handle directories and files */
            if (archive_entry_filetype (en) == AE_IFDIR) {
                if (!std.file.exists (pathname))
                    std.file.mkdir (pathname);
                continue;
            }

            if (archive_entry_filetype (en) == AE_IFREG) {
                this.extractEntryTo (ar, pathname);
            }
        }
    }

    const(ubyte)[] readData (string fname)
    {
        import core.sys.posix.sys.stat;
        import std.path;
        archive *ar;
        archive_entry *en;

        ar = openArchive ();
        scope(exit) archive_read_free (ar);

        auto fnameAbs = absolutePath (fname, "/");
        while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
            auto pathname = fromStringz (archive_entry_pathname (en));

            if (pathMatches (fname, to!string (pathname))) {
                auto filetype = archive_entry_filetype (en);

                if (filetype == S_IFDIR) {
                    /* we don't extract directories explicitly */
                    throw new Exception (format ("Path %s is a directory and can not be extracted.", fname));
                }

                /* check if we are dealing with a symlink */
                if (filetype == S_IFLNK) {
                    string linkTarget = to!string (fromStringz (archive_entry_symlink (en)));
                    if (linkTarget is null)
                        throw new Exception (format ("Unable to read destination of symbolic link for %s.", fname));

                    if (!isAbsolute (linkTarget))
                        linkTarget = absolutePath (linkTarget, dirName (fnameAbs));

                    return this.readData (buildNormalizedPath (linkTarget));
                }

                if (filetype != S_IFREG) {
                    // we really don't want to extract special files from a tarball - usually, those shouldn't
                    // be present anyway.
                    // This should probably be an error, but return nothing for now.
                    return null;
	            }

                return this.readEntry (ar);
		    } else {
                archive_read_data_skip (ar);
            }
        }

        throw new Exception (format ("File %s was not found in the archive.", fname));
    }

    string[] extractFilesByRegex (Regex!char re, string destdir)
    {
        import std.path;
        archive *ar;
        archive_entry *en;
        auto matches = appender!(string[]);

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

        return matches.data;
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

        auto contents = appender!(string[]);
        while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
            auto pathname = fromStringz (archive_entry_pathname (en));

            // ignore directories
            if (pathname.endsWith ("/"))
                continue;

            auto path = buildNormalizedPath ("/", to!string (pathname));
            contents ~= path;
        }

        return contents.data;
    }

    /**
     * Returns a generator to iterate over the contents of this tarball.
     */
    auto read ()
    {
        import core.sys.posix.sys.stat;
        import std.path;

        auto gen = new Generator!ArchiveEntry (
        {
            archive *ar;
            archive_entry *en;

            try {
                ar = openArchive ();
            } catch (Exception e) {
                throw e;
            }
            scope (exit) archive_read_free (ar);

            while (archive_read_next_header (ar, &en) == ARCHIVE_OK) {
                auto pathname = fromStringz (archive_entry_pathname (en));

                // ignore directories
                if (pathname.endsWith ("/"))
                    continue;

                auto path = std.path.buildNormalizedPath ("/", to!string (pathname));

                ArchiveEntry aentry;
                aentry.fname = path;
                aentry.data = null;

                auto filetype = archive_entry_filetype (en);
                /* check if we are dealing with a symlink */
                if (filetype == S_IFLNK) {
                    auto linkTarget = to!string (fromStringz (archive_entry_symlink (en)));
                    if (linkTarget is null)
                        throw new Exception (format ("Unable to read destination of symbolic link for %s.", path));

                    // we cheat here and set the link target as data
                    // TODO: Proper handling of symlinks, e.g. by adding a filetype property to ArchiveEntry.
                    aentry.data = cast(ubyte[]) linkTarget;
                    yield (aentry);
                    continue;
                }

                if (filetype != S_IFREG) {
                    yield (aentry);
                    continue;
                }

                aentry.data = this.readEntry (ar);
                yield (aentry);
            }
        });

        return gen;
    }
}

/**
 * Save data to a compressed file.
 *
 * Params:
 *      data = The data to save.
 *      fname = The filename the data should be saved to.
 *      atype = The archive type (GZ or XZ).
 */
void compressAndSave (ubyte[] data, const string fname, ArchiveType atype)
{
    archive *ar;

    ar = archive_write_new ();
    scope (exit) archive_write_free (ar);

    archive_write_set_format_raw (ar);
    if (atype == ArchiveType.GZIP) {
        archive_write_add_filter_gzip (ar);
        archive_write_set_filter_option (ar, "gzip", "timestamp", null);
    } else {
        archive_write_add_filter_xz (ar);
    }

    auto ret = archive_write_open_filename (ar, fname.toStringz);
    if (ret != ARCHIVE_OK)
        throw new Exception (format ("Unable to open file '%s': %s", fname, getArchiveErrorMessage (ar)));

    archive_entry *entry;
    entry = archive_entry_new ();
    scope (exit) archive_entry_free (entry);

    archive_entry_set_filetype (entry, AE_IFREG);
    archive_entry_set_size (entry, ubyte.sizeof * data.length);
    archive_write_header (ar, entry);

    archive_write_data (ar, cast(void*) data, ubyte.sizeof * data.length);
    archive_write_close (ar);
}

class ArchiveCompressor
{

private:
    string archiveFname;
    archive *ar;
    bool closed;

public:

    this (ArchiveType type)
    {
        ar = archive_write_new ();

        if (type == ArchiveType.GZIP) {
            archive_write_add_filter_gzip (ar);
            archive_write_set_filter_option (ar, "gzip", "timestamp", null);
        } else {
            archive_write_add_filter_xz (ar);
        }

        archive_write_set_format_pax_restricted (ar);
        closed = true;
    }

    ~this ()
    {
        close ();
        archive_write_free (ar);
    }

    void open (string fname)
    {
        archiveFname = fname;
        auto ret = archive_write_open_filename (ar, toStringz (fname));
        if (ret != ARCHIVE_OK)
            throw new Exception (format ("Unable to open file '%s'", fname, getArchiveErrorMessage (ar)));
        closed = false;
    }

    void close ()
    {
        if (closed)
            return;
        archive_write_close (ar);
        closed = true;
    }

    void addFile (string fname, string dest = null)
    in { assert (std.file.exists (fname)); }
    body
    {
        import std.conv : octal;
        import std.path : baseName;
        import core.sys.posix.sys.stat;

        immutable BUFFER_SIZE = 8192;
        archive_entry *entry;
        stat_t st;
        ubyte[BUFFER_SIZE] buff;

        if (dest is null)
            dest = baseName (fname);

        lstat (fname.toStringz, &st);
        entry = archive_entry_new ();
        scope (exit) archive_entry_free (entry);
        archive_entry_set_pathname (entry, toStringz (dest));

        archive_entry_set_size (entry, st.st_size);
        archive_entry_set_filetype (entry, S_IFREG);
        archive_entry_set_perm (entry, octal!755);
        archive_entry_set_mtime (entry, st.st_mtime, 0);

        synchronized (this) {
            archive_write_header (ar, entry);

            auto f = File (fname, "r");
            while (!f.eof) {
                auto data = f.rawRead (buff);
                archive_write_data (ar, cast(void*) data, ubyte.sizeof * data.length);
            }
        }
    }

}

unittest
{
    writeln ("TEST: ", "Compressed empty file");

    ubyte[] emptyGz = [
       0x1f, 0x8b, 0x08, 0x08, 0x00, 0x00, 0x00, 0x00,
       0x00, 0x03, 0x65, 0x6d, 0x70, 0x74, 0x79, 0x00,
       0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
       0x00, 0x00,
    ];
    assert (decompressData (emptyGz) == "");

    writeln ("TEST: ", "Extracting a tarball");

    import std.file : buildPath, tempDir;
    import utils : getTestSamplesDir;

    auto archive = buildPath (getTestSamplesDir (), "test.tar.xz");
    assert (std.file.exists (archive));
    auto ar = new ArchiveDecompressor ();

    auto tmpdir = buildPath (tempDir, "asgenXXXXXX");
    auto ctmpdir = new char[](tmpdir.length + 1);
    ctmpdir[0 .. tmpdir.length] = tmpdir[];
    ctmpdir[$ - 1] = '\0';

    tmpdir = to!string(mkdtemp (ctmpdir.ptr));
    scope(exit) std.file.rmdirRecurse (tmpdir);

    ar.open (archive);
    ar.extractArchive (tmpdir);

    auto path = buildPath (tmpdir, "b", "a");
    assert (std.file.exists (path));
    assert (std.file.readText (path).chomp == "hello");
}
