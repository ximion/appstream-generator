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

module asgen.fcmutex;
import core.sync.mutex;

private __gshared Mutex fontconfigMutex = null;

/**
 * Helper method required so we do not modify the Fontconfig
 * global state while reading it with another process.
 **/
void
enterFontconfigCriticalSection () @trusted
{
    if (fontconfigMutex is null)
        return;
    fontconfigMutex.lock ();
}

/**
 * Helper method required so we do not modify the Fontconfig
 * global state while reading it with another process.
 **/
void
leaveFontconfigCriticalSection () @trusted
{
    if (fontconfigMutex is null)
        return;
    fontconfigMutex.unlock ();
}

/**
 * Helper method required so we do not modify the Fontconfig
 * global state while reading it with another process.
 **/
void
setupFontconfigMutex () @trusted
{
    fontconfigMutex = new Mutex;
}
