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

module ag.backend.debian.tagfile;

import std.stdio;
import std.string;
import ag.archive;


class TagFile
{

private:
    string content[];
    uint pos;

public:

    this ()
    {
    }

    void open (string fname)
    {
        content = null;
        string data;

        try {
            data = decompressFile (fname);
        } catch (Exception e) {
            throw e;
        }

        content = splitLines (data);
        pos = 0;
    }

    void first () {
        pos = 0;
    }

    bool nextSection ()
    {
        auto clen = content.length;

        if (pos >= clen)
            return false;

        for (auto i = pos; i < clen; i++) {
            if (content[i] == "") {
                pos = i + 1;
                break;
            }
        }

        if (pos >= clen)
            return false;

        return true;
    }

    string readField (string name)
    {
        auto clen = content.length;

        for (auto i = pos; i < clen; i++) {
            if (content[i] == "")
                break;

            auto fdata = chompPrefix (content[i], name ~ ":");
            if (fdata == content[i])
                continue;


            if ((i+1 >= clen)
                || (!startsWith (content[i+1], " "))) {
                    // we have a single-line field
                    return strip (fdata);
            } else {
                // we have a multi-line field
                auto fdata_ml = strip (fdata);
                for (auto j = i+1; j < clen; j++) {
                    auto slice = chompPrefix (content[j], " ");
                    if (slice == content[j])
                        break;

                    if (fdata_ml == "")
                        fdata_ml = slice;
                    else
                        fdata_ml ~= "\n" ~ slice;
                }

                return fdata_ml;
            }
        }

        // we found nothing
        return null;
    }
}
