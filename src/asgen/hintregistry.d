/*
 * Copyright (C) 2016-2020 Matthias Klumpp <matthias@tenstral.net>
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

module asgen.hint;
@safe:

import std.stdio;
import std.string;
import std.json;
import std.conv : to;

import appstream.Validator : Validator;
import appstream.c.types : IssueSeverity;
import ascompose.Hint : Hint;
import ascompose.Globals : Globals;
static import appstream.Utils;
alias AsUtils = appstream.Utils.Utils;

import asgen.logging;
import asgen.utils;


/**
 * Each issue hint type has a severity assigned to it:

 * ERROR:   A fatal error which resulted in the component being excluded from the final metadata.
 * WARNING: An issue which did not prevent generating meaningful data, but which is still serious
 *          and should be fixed (warning of this kind usually result in less data).
 * INFO:    Information, no immediate action needed (but will likely be an issue later).
 * PEDANTIC: Information which may improve the data, but could also be ignored.
 */

/**
 * Definition of a issue hint.
 */
struct HintDefinition
{
    string tag;             /// Unique issue tag
    IssueSeverity severity; /// Issue severity
    string explanation;     /// Explanation template
}

/**
 * Load all issue hints from file and register them globally.
 */
void loadHintsRegistry () @trusted
{
    import std.path;
    static import std.file;

    // find the hint definition file
    auto hintsDefFile = getDataPath ("asgen-hints.json");
    if (!std.file.exists (hintsDefFile)) {
        logError ("Hints definition file '%s' was not found! This means we can not determine severity of issue tags and not render report pages.", hintsDefFile);
        return;
    }

    // read the hints definition JSON file
    auto f = File (hintsDefFile, "r");
    string jsonData;
    string line;
    while ((line = f.readln ()) !is null)
        jsonData ~= line;

    auto hintDefsJSON = parseJSON (jsonData);

    bool checkAlreadyLoaded = true;
    foreach (ref tag; hintDefsJSON.object.byKey) {
        auto j = hintDefsJSON[tag];
        immutable severity = AsUtils.severityFromString (j["severity"].str);

        if (checkAlreadyLoaded) {
            if (Globals.hintTagSeverity (tag) != IssueSeverity.UNKNOWN) {
                logDebug ("Global hints registry already loaded.");
                break;
            }
            checkAlreadyLoaded = false;
        }

        string explanation = "";
        if (j["text"].type == JSONType.array) {
            foreach (l; j["text"].array)
                explanation ~= l.str ~ "\n";
        } else {
            explanation = j["text"].str;
        }

        bool overrideExisting = false;
        if (tag == "icon-not-found")
            overrideExisting = true;

        if (!Globals.addHintTag (tag, severity, explanation, overrideExisting))
            logError ("Unable to override existing hint tag %s.", tag);
    }
}

/**
 * Save information about all hint templates we know about to a JSON file.
 */
void saveHintsRegistryToJsonFile (const string fname) @trusted
{
    // FIXME: is this really the only way you can set a type for JSONValue?
    auto map = JSONValue (["null": 0]);
    map.object.remove ("null");

    foreach (const htag; Globals.getHintTags) {
        const hdef = retrieveHintDef (htag);
        auto jval = JSONValue (["text": JSONValue (hdef.explanation),
                                "severity": JSONValue (AsUtils.severityToString (hdef.severity))]);
        map.object[hdef.tag] = jval;
    }

    File file = File(fname, "w");
    file.writeln (map.toJSON (true));
    file.close ();
}

HintDefinition retrieveHintDef (string tag) @trusted
{
    HintDefinition hdef;
    hdef.tag = tag;
    hdef.severity = Globals.hintTagSeverity (tag);
    if (hdef.severity == IssueSeverity.UNKNOWN)
        return HintDefinition ();
    hdef.explanation = Globals.hintTagExplanation (tag);
    return hdef;
}

auto toJsonValue (Hint hint) @trusted
{
    auto hintList = hint.getExplanationVarsList;
    string[string] vars;
    for (uint i = 0; i < hintList.len; i++) {
        if (i % 2 != 0)
            continue;
        const auto key = fromStringz (cast(char*) hintList.index (i)).to!string;
        const auto value = fromStringz (cast(char*) hintList.index (i + 1)).to!string;
        vars[key] = value;
    }

    return JSONValue(["tag":  JSONValue (hint.getTag),
                      "vars": JSONValue (vars)]);
}

@trusted
unittest
{
    import std.exception : assertThrown;
    import glib.GException : GException;
    writeln ("TEST: ", "Issue Hints");

    assertThrown!GException (new Hint ("icon-not-found"));

    loadHintsRegistry ();
    auto hint = new Hint ("icon-not-found");

    foreach (k, v; ["rainbows": "yes", "unicorns": "no", "storage": "towel"])
        hint.addExplanationVar (k, v);
    auto root = hint.toJsonValue ();
    writeln (root.toJSON (true));

    assert (retrieveHintDef ("asv-relation-item-invalid-vercmp").severity != IssueSeverity.UNKNOWN);
    saveHintsRegistryToJsonFile ("/tmp/testsuite-asgen-hints.json");
}
