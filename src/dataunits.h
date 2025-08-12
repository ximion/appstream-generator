/*
 * Copyright (C) 2016-2025 Matthias Klumpp <matthias@tenstral.net>
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

#include <glib-object.h>
#include <appstream-compose.h>
#include <memory>

#include <vector>

#include "contentsstore.h"
#include "backends/interfaces.h"

G_BEGIN_DECLS

#define ASG_TYPE_PACKAGE_UNIT (asg_package_unit_get_type())
G_DECLARE_FINAL_TYPE(AsgPackageUnit, asg_package_unit, ASG, PACKAGE_UNIT, AscUnit)

#define ASG_TYPE_LOCALE_UNIT (asg_locale_unit_get_type())
G_DECLARE_FINAL_TYPE(AsgLocaleUnit, asg_locale_unit, ASG, LOCALE_UNIT, AscUnit)

/**
 * Create a new package unit for a given package.
 */
AsgPackageUnit *asg_package_unit_new(std::shared_ptr<ASGenerator::Package> pkg);

/**
 * Create a new locale unit with contents store and package list.
 */
AsgLocaleUnit *asg_locale_unit_new(
    std::shared_ptr<ASGenerator::ContentsStore> cstore,
    std::vector<std::shared_ptr<ASGenerator::Package>> pkgList);

G_END_DECLS
