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

module handlers.metainfovalidator;

import std.path : baseName;
import std.uni : toLower;
import std.string : format;
import std.stdio;
import appstream.Validator;
import appstream.ValidatorIssue;
import appstream.Component;
import glib.ListG;
import gobject.ObjectG;

import result;
import utils;


void validateMetaInfoFile (Component cpt, GeneratorResult res, string data)
{
    auto validator = new Validator ();

    try {
        validator.validateData (data);
    } catch (Exception e) {
        res.addHint (cpt.getId (), "metainfo-validation-issue", "The file could not be validated due to an error: " ~ e.msg);
        return;
    }

    auto issueList = validator.getIssues ();
    for (ListG l = issueList; l !is null; l = l.next) {
        auto issue = ObjectG.getDObject!ValidatorIssue (cast (typeof(ValidatorIssue.tupleof[0])) l.data);

        // we have a special hint tag for legacy metadata
        if (issue.getKind () == IssueKind.LEGACY) {
            res.addHint (cpt.getId (), "ancient-metadata");
            continue;
        }

        auto importance = issue.getImportance ();
        auto msg = issue.getMessage();

        if ((importance == IssueImportance.PEDANTIC) || (importance == IssueImportance.INFO)) {
            res.addHint (cpt.getId (), "metainfo-validation-hint", msg);
        } else {
            res.addHint (cpt.getId (), "metainfo-validation-issue", msg);
        }
    }
}
