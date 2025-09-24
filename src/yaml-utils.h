/*
 * Copyright (C) 2018-2025 Matthias Klumpp <matthias@tenstral.net>
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

#pragma once

#include <string>
#include <vector>
#include <memory>
#include <libfyaml.h>

namespace ASGenerator
{

namespace Yaml
{

using YDocumentPtr = std::unique_ptr<fy_document, decltype(&fy_document_destroy)>;

YDocumentPtr parseDocument(const std::string &yamlData, bool forceJson = false);
fy_node *documentRoot(YDocumentPtr &doc);

std::string nodeStrValue(fy_node *node, std::string defaultValue = {});
int64_t nodeIntValue(fy_node *node, int64_t defaultValue = 0);
bool nodeBoolValue(fy_node *node, bool defaultValue = false);
std::vector<std::string> nodeArrayValues(fy_node *node);
fy_node *nodeByKey(fy_node *mapping, const std::string &key);

YDocumentPtr createDocument();

std::string libfyamlVersion() noexcept;

} // namespace Yaml

} // namespace ASGenerator
