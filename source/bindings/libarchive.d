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

module c.libarchive;

import core.stdc.stdio;
import std.conv : octal;

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

immutable AE_IFMT   = octal!170000;
immutable AE_IFREG  = octal!100000;
immutable AE_IFLNK  = octal!120000;
immutable AE_IFSOCK = octal!140000;
immutable AE_IFCHR  = octal!20000;
immutable AE_IFBLK  = octal!60000;
immutable AE_IFDIR  = octal!40000;
immutable AE_IFIFO  = octal!10000;

const(char) *archive_error_string (archive*);
int archive_errno (archive*);

archive *archive_read_new ();
int archive_read_free (archive*);

int archive_read_support_filter_all (archive*);
int archive_read_support_filter_gzip (archive*);
int archive_read_support_filter_lzma (archive*);

int archive_read_support_format_raw (archive*);
int archive_read_support_format_empty (archive*);
int archive_read_support_format_all (archive*);
int archive_read_support_format_ar (archive*);
int archive_read_support_format_gnutar (archive*);

int archive_write_set_filter_option (archive *a, const(char) *m, const(char) *o, const(char) *v);

int archive_read_open_filename (archive*, const(char) *filename, usize block_size);
int archive_read_open_FILE (archive*, FILE *file);
int archive_read_open_memory (archive*, void *buff, size_t size);

ptrdiff_t archive_read_data (archive*, void*, usize);
int archive_read_next_header (archive*, archive_entry**);
int archive_read_data_skip (archive*);
int archive_read_data_block (archive *a, const(void*) *buff, size_t *size, long *offset);

archive_entry *archive_entry_new ();
void archive_entry_free (archive_entry*);

const(char) *archive_entry_pathname (archive_entry*);
void archive_entry_set_pathname (archive_entry*, const(char) *);
uint archive_entry_filetype (archive_entry*);
void archive_entry_set_size (archive_entry*, long);
void archive_entry_set_filetype (archive_entry*, uint);
void archive_entry_set_perm (archive_entry*, uint);
void archive_entry_set_mtime (archive_entry*, ulong sec, long nsec);
const(char)	*archive_entry_symlink (archive_entry*);

archive *archive_write_new ();
int archive_write_free (archive*);
int archive_write_close (archive*);

int archive_write_add_filter_gzip (archive*);
int archive_write_add_filter_xz (archive*);
int archive_write_set_format_pax (archive*);
int archive_write_set_format_pax_restricted (archive*);
int archive_write_set_format_raw (archive*);
//int archive_write_set_format_raw (archive *a); /// Will be available in the next version of libarchive (to be released in 2016)
int archive_write_set_format_by_name (archive*, const(char) *name);

int archive_write_open_filename (archive*, const(char) *file);
int archive_write_header (archive*, archive_entry*);
size_t archive_write_data(archive*, const(void)*, size_t);
