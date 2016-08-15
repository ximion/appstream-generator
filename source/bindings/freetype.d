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

module bindings.freetype;

extern(C):
nothrow:
@nogc:

alias FT_Error = int;
alias FT_Byte = ubyte;
alias FT_Long = long;

immutable FT_LOAD_DEFAULT = 0x0;

struct FT_LibraryRec_ {}
alias FT_Library = FT_LibraryRec_*;

struct FT_FaceRec_ {}
alias FT_Face = FT_FaceRec_*;

FT_Error FT_Init_FreeType (FT_Library *alibrary);
FT_Error FT_Done_FreeType (FT_Library  library);

FT_Error FT_New_Face (FT_Library library,
                      const(char) *filepathname,
                      FT_Long face_index,
                      FT_Face *aface);
FT_Error FT_New_Memory_Face (FT_Library library,
                             const FT_Byte *file_base,
                             FT_Long file_size,
                             FT_Long face_index,
                             FT_Face *aface);
FT_Error FT_Done_Face (FT_Face face);
