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

module bindings.fontconfig;

extern(C):
nothrow:

alias FcChar8 = char;
alias FcBool = int;

struct FcPattern {};
struct FcConfig {};

struct FcMatrix {};
struct FcCharSet {};
struct FcLangSet {};
struct FcRange {}

struct FcStrList {};
struct FcStrSet {};

immutable char *FC_LANG = "lang"; // String RFC 3066 langs

struct FcFontSet {
    int nfont;
    int sfont;
    FcPattern **fonts;
};

enum FcType {
    Unknown = -1,
    Void,
    Integer,
    Double,
    String,
    Bool,
    Matrix,
    CharSet,
    FTFace,
    LangSet
};

struct FcValue
{
    FcType type;
    union {
        const FcChar8 *s;
        int i;
        FcBool b;
        double d;
        const FcMatrix *m;
        const FcCharSet *c;
        void *f;
        const FcLangSet *l;
        const FcRange *r;
    };
};

enum FcSetName
{
    System = 0,
    Application = 1
};

enum FcResult {
    Match,
    NoMatch,
    TypeMismatch,
    NoId,
    OutOfMemory
};

FcConfig *FcConfigCreate ();
void FcConfigDestroy (FcConfig *config);

void FcConfigAppFontClear (FcConfig *config);
bool FcConfigSetCurrent (FcConfig *config);
bool FcConfigAppFontAddFile (FcConfig *config,
                             const char *file);
FcFontSet *FcConfigGetFonts (FcConfig *config,
                             FcSetName set);

FcResult FcPatternGet (const FcPattern *p,
                        const char *object,
                        int id,
                        FcValue *v);
FcResult FcPatternGetLangSet (const FcPattern *p,
                              const char *object,
                              int n,
                              FcLangSet **ls);

FcStrList *FcStrListCreate (FcStrSet *set);
void FcStrListFirst (FcStrList *list);
char *FcStrListNext (FcStrList *list);
void FcStrListDone (FcStrList *list);

FcStrSet *FcLangSetGetLangs (const FcLangSet *ls);
void FcStrSetDestroy (FcStrSet *set);
