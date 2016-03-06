/*
 * @author Howard Chu, Symas Corporation.
 *
 * @copyright Copyright 2011-2015 Howard Chu, Symas Corp. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted only as authorized by the OpenLDAP
 * Public License.
 *
 * A copy of this license is available in the file LICENSE in the
 * top-level directory of the distribution or, alternatively, at
 * <http://www.OpenLDAP.org/license.html>.
 *
 * @par Derived From:
 * This code is derived from btree.c written by Martin Hedenfalk.
 *
 * Copyright (c) 2009, 2010 Martin Hedenfalk <martin@bzero.se>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */
module lmdb;

// ////////////////////////////////////////////////////////////////////////// //
// C API
extern(C):
nothrow:
@nogc:

static if (!is(typeof(usize))) private alias usize = size_t;
alias mdb_mode_t = uint;
struct mdb_filehandle_ts {}
alias mdb_filehandle_t = mdb_filehandle_ts*;

enum {
  MDB_VERSION_MAJOR = 0,
  MDB_VERSION_MINOR = 9,
  MDB_VERSION_PATCH = 18,
  MDB_VERSION_DATE = "December 19, 2015",
}

struct MDB_env_s {}
alias MDB_envp = MDB_env_s*;
struct MDB_txn_s {}
alias MDB_txnp = MDB_txn_s*;
alias MDB_dbi = uint;
struct MDB_cursor_s {}
alias MDB_cursorp = MDB_cursor_s*;

struct MDB_val {
  usize mv_size;
  void* mv_data;
}

enum {
  MDB_FIXEDMAP = 0x01,
  MDB_NOSUBDIR = 0x4000,
  MDB_NOSYNC = 0x10000,
  MDB_RDONLY = 0x20000,
  MDB_NOMETASYNC = 0x40000,
  MDB_WRITEMAP = 0x80000,
  MDB_MAPASYNC = 0x100000,
  MDB_NOTLS = 0x200000,
  MDB_NOLOCK = 0x400000,
  MDB_NORDAHEAD = 0x800000,
  MDB_NOMEMINIT = 0x1000000
}

enum {
  MDB_REVERSEKEY = 0x02,
  MDB_DUPSORT = 0x04,
  MDB_INTEGERKEY = 0x08,
  MDB_DUPFIXED = 0x10,
  MDB_INTEGERDUP = 0x20,
  MDB_REVERSEDUP = 0x40,
  MDB_CREATE = 0x40000
}

enum {
  MDB_NOOVERWRITE = 0x10,
  MDB_NODUPDATA = 0x20,
  MDB_RESERVE = 0x10000,
  MDB_APPEND = 0x20000,
  MDB_APPENDDUP = 0x40000,
  MDB_MULTIPLE = 0x80000
}

enum /*MDB_cursor_op*/ {
  MDB_FIRST,
  MDB_FIRST_DUP,
  MDB_GET_BOTH,
  MDB_GET_BOTH_RANGE,
  MDB_GET_CURRENT,
  MDB_GET_MULTIPLE,
  MDB_LAST,
  MDB_LAST_DUP,
  MDB_NEXT,
  MDB_NEXT_DUP,
  MDB_NEXT_MULTIPLE,
  MDB_NEXT_NODUP,
  MDB_PREV,
  MDB_PREV_DUP,
  MDB_PREV_NODUP,
  MDB_SET,
  MDB_SET_KEY,
  MDB_SET_RANGE,
}

enum {
  MDB_SUCCESS = 0,
  MDB_KEYEXIST = (-30799),
  MDB_NOTFOUND = (-30798),
  MDB_PAGE_NOTFOUND = (-30797),
  MDB_CORRUPTED = (-30796),
  MDB_PANIC = (-30795),
  MDB_VERSION_MISMATCH = (-30794),
  MDB_INVALID = (-30793),
  MDB_MAP_FULL = (-30792),
  MDB_DBS_FULL = (-30791),
  MDB_READERS_FULL = (-30790),
  MDB_TLS_FULL = (-30789),
  MDB_TXN_FULL = (-30788),
  MDB_CURSOR_FULL = (-30787),
  MDB_PAGE_FULL = (-30786),
  MDB_MAP_RESIZED = (-30785),
  MDB_INCOMPATIBLE = (-30784),
  MDB_BAD_RSLOT = (-30783),
  MDB_BAD_TXN = (-30782),
  MDB_BAD_VALSIZE = (-30781),
  MDB_BAD_DBI = (-30780),
  MDB_LAST_ERRCODE = MDB_BAD_DBI
}

struct MDB_stat {
  uint ms_psize;
  uint ms_depth;
  usize ms_branch_pages;
  usize ms_leaf_pages;
  usize ms_overflow_pages;
  usize ms_entries;
}

struct MDB_envinfo {
  void* me_mapaddr;
  usize me_mapsize;
  usize me_last_pgno;
  usize me_last_txnid;
  uint me_maxreaders;
  uint me_numreaders;
}

const(char)* mdb_version (int* major, int* minor, int* patch);
const(char)* mdb_strerror (int err);

int mdb_env_create (MDB_envp* env);
int mdb_env_open (MDB_envp env, const(char)* path, uint flags, mdb_mode_t mode);
int mdb_env_copy (MDB_envp env, const(char)* path);
int mdb_env_copyfd (MDB_envp env, mdb_filehandle_t fd);
int mdb_env_stat (MDB_envp env, MDB_stat* stat);
int mdb_env_info (MDB_envp env, MDB_envinfo* stat);
int mdb_env_sync (MDB_envp env, int force);
void mdb_env_close (MDB_envp env);
int mdb_env_set_flags (MDB_envp env, uint flags, int onoff);
int mdb_env_get_flags (MDB_envp env, uint* flags);
int mdb_env_get_path (MDB_envp env, const(char)** path);
int mdb_env_get_fd (MDB_envp env, mdb_filehandle_t* fd);
int mdb_env_set_mapsize (MDB_envp env, usize size);
int mdb_env_set_maxreaders (MDB_envp env, uint readers);
int mdb_env_get_maxreaders (MDB_envp env, uint* readers);
int mdb_env_set_maxdbs (MDB_envp env, MDB_dbi dbs);
int mdb_env_get_maxkeysize (MDB_envp env);
int mdb_env_set_userctx (MDB_envp env, void* ctx);
void* mdb_env_get_userctx (MDB_envp env);
int mdb_env_set_assert (MDB_envp env, void function (MDB_envp env, const(char)* msg) func);

int mdb_txn_begin (MDB_envp env, MDB_txnp parent, uint flags, MDB_txnp* txn);
MDB_envp mdb_txn_env (MDB_txnp txn);
usize mdb_txn_id (MDB_txnp txn);
int mdb_txn_commit (MDB_txnp txn);
void mdb_txn_abort (MDB_txnp txn);
void mdb_txn_reset (MDB_txnp txn);
int mdb_txn_renew (MDB_txnp txn);

int mdb_dbi_open (MDB_txnp txn, const(char)* name, uint flags, MDB_dbi* dbi);
int mdb_stat (MDB_txnp txn, MDB_dbi dbi, MDB_stat* stat);
int mdb_dbi_flags (MDB_txnp txn, MDB_dbi dbi, uint* flags);
void mdb_dbi_close (MDB_envp env, MDB_dbi dbi);
int mdb_drop (MDB_txnp txn, MDB_dbi dbi, int del);
int mdb_set_compare (MDB_txnp txn, MDB_dbi dbi, int function (MDB_val* a, MDB_val* b) cmp);
int mdb_set_dupsort (MDB_txnp txn, MDB_dbi dbi, int function (MDB_val* a, MDB_val* b) cmp);
int mdb_set_relfunc (MDB_txnp txn, MDB_dbi dbi, void function (MDB_val* item, void* oldptr, void* newptr, void* relctx) rel);
int mdb_set_relctx (MDB_txnp txn, MDB_dbi dbi, void* ctx);
int mdb_get (MDB_txnp txn, MDB_dbi dbi, MDB_val* key, MDB_val* data);
int mdb_put (MDB_txnp txn, MDB_dbi dbi, MDB_val* key, MDB_val* data, uint flags);
int mdb_del (MDB_txnp txn, MDB_dbi dbi, MDB_val* key, MDB_val* data);
int mdb_cursor_open (MDB_txnp txn, MDB_dbi dbi, MDB_cursorp* cursor);
void mdb_cursor_close (MDB_cursorp cursor);
int mdb_cursor_renew (MDB_txnp txn, MDB_cursorp cursor);
MDB_txnp mdb_cursor_txn (MDB_cursorp cursor);
MDB_dbi mdb_cursor_dbi (MDB_cursorp cursor);
int mdb_cursor_get (MDB_cursorp cursor, MDB_val* key, MDB_val* data, /*MDB_cursor_op*/uint op);
int mdb_cursor_put (MDB_cursorp cursor, MDB_val* key, MDB_val* data, uint flags);
int mdb_cursor_del (MDB_cursorp cursor, uint flags);
int mdb_cursor_count (MDB_cursorp cursor, usize* countp);
int mdb_cmp (MDB_txnp txn, MDB_dbi dbi, MDB_val* a, MDB_val* b);
int mdb_dcmp (MDB_txnp txn, MDB_dbi dbi, MDB_val* a, MDB_val* b);
int mdb_reader_list (MDB_envp env, int function (const(char)* msg, void* ctx) func, void* ctx);
int mdb_reader_check (MDB_envp env, int* dead);
