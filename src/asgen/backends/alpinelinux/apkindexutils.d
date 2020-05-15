module asgen.backends.alpinelinux.apkindexutils;

import std.algorithm : remove;
import std.algorithm.iteration : map;
import std.algorithm.searching : canFind;
import std.array : join, split;
import std.file : exists;
import std.format : format;
import std.path : buildPath;
import std.range : empty, InputRange, isForwardRange;
import std.string : splitLines, startsWith, strip;
import std.utf : validate;

import std.stdio;

import asgen.backends.alpinelinux.apkpkg;
import asgen.downloader : Downloader, DownloadException;
import asgen.logging : logDebug;
import asgen.utils : isRemote;

/**
* Struct representing a block inside of an APKINDEX. Each block, seperated by
* a newline, contains information about exactly one package.
*/
struct ApkIndexBlock {
    string arch;
    string maintainer;
    string pkgname;
    string pkgversion;
    string pkgdesc;

    @property string archiveName () {
        return format ("%s-%s.apk", this.pkgname, this.pkgversion);
    }
}

/**
* Range for looping over the contents of an APKINDEX, block by block.
*/
struct ApkIndexBlockRange {
    this (string contents)
    {
        this.lines = contents.splitLines;
        this.getNextBlock();
    }

    @property ApkIndexBlock front () const {
        return this.currentBlock;
    }

    @property bool empty () {
        return this.m_empty;
    }

    void popFront ()
    {
        this.getNextBlock ();
    }

    @property ApkIndexBlockRange save () { return this; }

private:
    void getNextBlock () {
        string[] completePair;
        uint iterations = 0;

        currentBlock = ApkIndexBlock();
        foreach (currentLine; this.lines[this.lineDelta .. $]) {
            iterations++;
            if (currentLine == "") {
                // next block for next package started
                break;
            } if (currentLine.canFind (":")) {
                if (completePair.empty) {
                    completePair = [currentLine];
                    continue;
                }

                auto pair = completePair.join (" ").split (":");
                this.setCurrentBlock (pair[0], pair[1]);
                completePair = [currentLine];
            } else {
                completePair ~= currentLine.strip ();
            }
        }

        this.lineDelta += iterations;
        this.m_empty = this.lineDelta == this.lines.length;
    }

    void setCurrentBlock (string key, string value) {
        switch (key) {
            case "A":
                this.currentBlock.arch = value;
                break;
            case "m":
                this.currentBlock.maintainer = value;
                break;
            case "P":
                this.currentBlock.pkgname = value;
                break;
            case "T":
                this.currentBlock.pkgdesc = value;
                break;
            case "V":
                this.currentBlock.pkgversion = value;
                break;
            default:
                // We dont care about other keys
                break;
        }
    }

    string[] lines;
    ApkIndexBlock currentBlock;
    bool m_empty;
    uint lineDelta;
}

static assert (isForwardRange!ApkIndexBlockRange);

/**
 * Download apkindex if required. Returns the path to the local copy of the APKINDEX.
 */
immutable (string) downloadIfNecessary (const string prefix,
                                        const string destPrefix,
                                        const string srcFileName,
                                        const string destFileName)
{
    auto downloader = Downloader.get;

    immutable filePath = buildPath (prefix, srcFileName);
    immutable destFilePath = buildPath (destPrefix, destFileName);

    if (filePath.isRemote) {
        try {
            downloader.downloadFile (filePath, destFilePath);

            return destFilePath;
        } catch (DownloadException e) {
            logDebug ("Unable to download: %s", e.msg);
        }
    } else {
        if (filePath.exists)
            return filePath;
    }

    /* all extensions failed, so we failed */
    throw new Exception ("Could not obtain any file matching %s".format (buildPath (prefix, srcFileName)));
}
