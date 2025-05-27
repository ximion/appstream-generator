/*
 * Copyright (C) 2025 Victor Fuentes <vlinkz@snowflakeos.org>
 *
 * Based on the archlinux and alpinelinux backends, which are:
 * Copyright (C) 2016 Matthias Klumpp <matthias@tenstral.net>
 * Copyright (C) 2020 Rasmus Thomsen <oss@cogitri.dev>
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

module asgen.backends.nix.nixindexutils;

import std.file : dirEntries, exists, readText, SpanMode;
import std.format : format;
import std.json : parseJSON, JSONValue;
import std.parallelism : parallel, defaultPoolThreads;
import std.path : baseName, buildNormalizedPath, extension;
import std.process : execute, pipeProcess, Redirect, wait;
import std.range : empty;
import std.regex : matchFirst;
import std.stdio : File;
import std.string : strip;

import glib.Util : Util;

import asgen.downloader : Downloader, DownloadException;
import asgen.logging : logDebug, logError, logInfo, logWarning;

immutable(string) generateNixPackagesIfNecessary (
        const string nixExe,
        const string suite,
        const string section,
        const string destFilePath
)
{
    if (destFilePath.exists) {
        return destFilePath;
    }

    auto nixEnvExe = Util.findProgramInPath("nix-env");
    if (nixEnvExe.empty) {
        throw new Exception("nix-env binary not found. Cannot extract packages.json.br");
    }

    auto nixpkgsPathResult = execute([
        nixExe,
        "--extra-experimental-features",
        "nix-command flakes",
        "eval",
        "--quiet",
        format("%s/%s#path", suite, section)
    ]);

    if (nixpkgsPathResult.status != 0) {
        throw new Exception(format("nix eval failed: %s", nixpkgsPathResult.output));
    }

    logDebug("Building nixpkgs packages.json, this may take a while");
    auto nixpkgsPath = buildNormalizedPath(nixpkgsPathResult.output.strip());
    auto pipes = pipeProcess([
        nixEnvExe,
        "-qaP",
        "--out-path",
        "--meta",
        "--json",
        "--file",
        nixpkgsPath,
        "--arg",
        "config",
        format("import %s/pkgs/top-level/packages-config.nix", nixpkgsPath)
    ]);
    string stderr_output;

    auto outFile = File(destFilePath, "w");
    outFile.write("{\"version\":2,\"packages\":");
    foreach (line; pipes.stdout.byLine) {
        outFile.writeln(line);
    }
    foreach (line; pipes.stderr.byLine) {
        stderr_output ~= line ~ "\n";
    }

    auto result = wait(pipes.pid);
    outFile.write("}");
    outFile.close();

    if (result != 0) {
        throw new Exception(format("nix-env failed: %s", stderr_output));
    }

    return destFilePath;
}

string[string] getInterestingNixPkgs (const string nixExe, const string indexPath, const string storeUrl, JSONValue packagesJson)
{
    string[string] interestingPkgs;

    string[string] pkgsToCheck;
    foreach (attr, pkg; packagesJson.object["packages"].object) {
        if (
            matchFirst(attr, r"^python3.*Packages\.") ||
                matchFirst(attr, r"^haskellPackages\.")
            ) {
            continue;
        }
        if (auto outputs = "outputs" in pkg.object) {
            foreach (output, outPath; outputs.object) {
                pkgsToCheck[format("%s.%s", attr, output)] = outPath.str();
            }
        }
    }

    if (!exists(indexPath)) {
        logDebug("Index %s directory doesn't exist, running parallel nix store ls...", indexPath);

        auto bashScript = format(`
mkdir -p $INDEXPATH
echo "" > count

cat | xargs -P %s -I {} bash -c '\
    echo 0 >> count
    if result=$(%s store ls --store "%s" "{}" --json -R --quiet 2>/dev/null); then
        echo "$result" > "$INDEXPATH/$(basename "{}").json"
    fi
'
`, defaultPoolThreads(), nixExe, storeUrl);

        string[string] env;
        env["INDEXPATH"] = indexPath;

        auto pipes = pipeProcess(["bash", "-c", bashScript], Redirect.stdin, env);
        foreach (attr, outPath; pkgsToCheck) {
            pipes.stdin.writeln(outPath);
        }
        pipes.stdin.close();

        auto result = wait(pipes.pid);

        if (result != 0) {
            logError("Nix indexing script failed: %s", result);
            return interestingPkgs;
        }

        logDebug("Parallel nix store ls completed");
    } else {
        logDebug("Index directory exists, using cached results");
    }

    foreach (entry; parallel(dirEntries(indexPath, SpanMode.shallow))) {
        if (entry.name.extension != ".json")
            continue;

        try {
            auto content = readText(entry.name);
            auto paths = parseJSON(content);
            auto outPath = "/nix/store/" ~ baseName(entry.name, ".json");

            string attr;
            foreach (a, p; pkgsToCheck) {
                if (p == outPath) {
                    attr = a;
                    break;
                }
            }

            if (attr.empty) {
                logWarning("Could not find attribute for path: %s", outPath);
                continue;
            }

            if (auto entries = "entries" in paths.object) {
                if (auto share = "share" in entries.object) {
                    if (share.object["type"].str == "symlink") {
                        interestingPkgs[attr] = outPath;
                        continue;
                    } else if (share.object["type"].str == "directory") {
                        if (auto shareEntries = "entries" in share.object) {
                            if ("applications" in shareEntries.object) {
                                interestingPkgs[attr] = outPath;
                                continue;
                            }
                        }
                    }
                }
            }
        } catch (Exception e) {
            logWarning("Failed to process result file %s: %s", entry.name, e.msg);
        }
    }

    return interestingPkgs;
}

ubyte[] nixStoreCat (const string nixExe, const string storeUrl, const string path)
{
    auto pipes = pipeProcess([
        nixExe,
        "--extra-experimental-features",
        "nix-command",
        "store",
        "cat",
        "--store",
        storeUrl,
        "--quiet",
        path,
    ], Redirect.stdout | Redirect.stderr);
    string stdout;
    foreach (line; pipes.stdout.byLine)
        stdout ~= line ~ "\n";
    string stderr;
    foreach (line; pipes.stderr.byLine)
        stderr ~= line ~ "\n";

    auto result = wait(pipes.pid);
    if (result != 0) {
        logError("nix store cat failed: %s", stderr);
        return [' '];
    }
    return cast(ubyte[]) stdout;
}

immutable(JSONValue) nixStoreLs (const string nixExe, const string storeUrl, const string path)
{
    auto pipes = pipeProcess([
        nixExe,
        "--extra-experimental-features",
        "nix-command",
        "store",
        "ls",
        "--store",
        storeUrl,
        "--recursive",
        "--json",
        "--quiet",
        path,
    ], Redirect.stdout | Redirect.stderr);
    string stdout;
    foreach (line; pipes.stdout.byLine)
        stdout ~= line ~ "\n";
    string stderr;
    foreach (line; pipes.stderr.byLine)
        stderr ~= line ~ "\n";

    auto result = wait(pipes.pid);
    if (result != 0) {
        throw new Exception(format("nix store ls failed: %s", stderr));
    }
    return parseJSON(stdout);
}
