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

module libarchive;

import std.cstream;

extern(C):
nothrow:
@nogc:
static if (!is(typeof(usize))) private alias usize = size_t;

struct archive {}
struct archive_entry {}

immutable ARCHIVE_EOF = 1;     /* Found end of archive. */
immutable ARCHIVE_OK  = 0;	   /* Operation was successful. */
immutable ARCHIVE_RETRY	= -10; /* Retry might succeed. */
immutable ARCHIVE_WARN  = -20; /* Partial success. */
immutable ARCHIVE_FAILED = -25; /* Current operation cannot complete. */
immutable ARCHIVE_FATAL = -30;  /* No more operations are possible. */

archive *archive_read_new ();
int archive_read_free (archive*);

int archive_read_support_compression_all (archive*);
int archive_read_support_format_raw (archive*);
int archive_read_support_format_all (archive*);
int archive_read_support_filter_all (archive*);

int archive_read_open_filename (archive*, const(char) *filename, usize block_size);
int archive_read_open_FILE (archive*, FILE *file);

ptrdiff_t archive_read_data(archive*, void*, usize);
int archive_read_next_header (archive*, archive_entry**);
int archive_read_data_skip (archive*);
int archive_read_data_block(archive *a, const(void*) *buff, size_t *size, long *offset);

const(char) *archive_entry_pathname (archive_entry*);
int archive_entry_filetype (archive_entry*);
