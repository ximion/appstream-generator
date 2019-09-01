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

module asgen.handlers.metainfovalidator;

import std.path : baseName;
import std.uni : toLower;
import std.string : format;
import std.stdio;
import std.typecons : scoped;

import appstream.Validator : Validator;
import appstream.ValidatorIssue;
import appstream.Component;
import glib.ListG;
import gobject.ObjectG;

import asgen.result;
import asgen.utils;


void validateMetaInfoFile (GeneratorResult res, Component cpt, string data, string miBasename)
{
    // create thread-local validator for efficiency
    static Validator validator = null;
    if (validator is null)
        validator = new Validator;

    validator.setCheckUrls (false); // don't check web URLs for validity
    validator.clearIssues (); // remove issues from a previous use of this validator

    try {
        validator.validateData (data);
    } catch (Exception e) {
        res.addHint (cpt.getId (), "metainfo-validation-error", e.msg);
        return;
    }

    auto issueList = validator.getIssues ();
    for (ListG l = issueList; l !is null; l = l.next) {
        auto issue = ObjectG.getDObject!ValidatorIssue (cast (typeof(ValidatorIssue.tupleof[0])) l.data);

        // create a tag for asgen out of the AppStream validator tag by prefixing it
        immutable asvTag = "asv-%s".format (issue.getTag);

        // we have a special hint tag for legacy metadata,
        // with its proper "error" priority
        if (asvTag == "asv-metainfo-ancient") {
            res.addHint (cpt.getId (), "ancient-metadata");
            continue;
        }

        immutable line = issue.getLine;
        string location;
        if (line >= 0)
            location = "%s:%s".format (miBasename, line);
        else
            location = miBasename;

        // we don't need to do much here, with the tag generated here,
        // the hint registry will automatically assign the right explanation
        // text and severity to the issue.
        res.addHint (cpt, asvTag, ["location": location,
                                   "hint": issue.getHint]);
    }
}
