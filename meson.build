project('AppStream Generator', 'cpp',
    meson_version : '>=1.0',
    default_options : ['c_std=c23', 'cpp_std=c++23'],
    subproject_dir : 'contrib/subprojects',
    license : 'LGPL-3.0+',
    version : '1.0.0'
)

asgen_version = meson.project_version()

source_root = meson.project_source_root()
build_root = meson.project_build_root()
cxx = meson.get_compiler('cpp')

fs = import('fs')

#
# Dependencies
#
src_dir = include_directories('src/')

glib_dep      = dependency('glib-2.0', version: '>= 2.80')
appstream_dep = dependency('appstream', version: '>= 1.2.0')
ascompose_dep = dependency('appstream-compose', version: '>= 1.2.0')
lmdb_dep      = dependency('lmdb', version: '>= 0.9.22')
archive_dep   = dependency('libarchive', version: '>= 3.2')
curl_dep      = dependency('libcurl')
fyaml_dep     = dependency('libfyaml', version: '>= 0.9.2')
tbb_dep       = dependency('tbb')
icu_dep       = dependency('icu-uc')
libxml2_dep   = dependency('libxml-2.0') # for rpmmd
catch2_dep    = dependency('catch2-with-main')
nljson_dep    = dependency('nlohmann_json', version: '>= 3.11.2')
quill_dep     = dependency('quill', version: '>= 11.1', fallback: ['quill', 'quill_dep']).as_system()
inja_dep      = dependency('inja', version: '>= 3.5.0',
                            fallback: ['inja', 'inja_dep'], default_options: ['build_tests=false']).as_system()

backward_deps = []
backward_dep = dependency('', required: false)
if get_option('backward')
    backward_dep = dependency('Backward', method: 'cmake', required: false).as_system()
    if not backward_dep.found()
        # Fall back to a bundled copy. We only ever need the headers.
        backward_dep = dependency(
            'backward-cpp-interface',
            fallback: ['backward-cpp', 'backward_interface_dep'],
            required: false
        ).as_system()
    endif
    if backward_dep.found()
        message('Using backward-cpp for stack traces')
        backward_deps = [backward_dep]
    endif
endif

# Ensure we have a compiler that can handle the C++23 features we need
if cxx.get_id() == 'gcc'
    if not cxx.version().version_compare('>=14.0')
        error('GCC 14 or newer is required to build this project')
    endif
elif cxx.get_id() == 'clang'
    if not cxx.version().version_compare('>=18.0')
        error('Clang 18 or newer is required to build this project')
    endif
    # Clang/libc++ needs an additional flag to enable some experimental stuff
    add_project_arguments('-fexperimental-library', language: 'cpp')
endif

#
# Compiler flags
#

if get_option('maintainer')
    maintainer_c_args = [
        '-Werror',
        '-Wall',
        '-Wextra',
        '-Wcast-align',
        '-Wno-uninitialized',
        '-Wempty-body',
        '-Wformat-security',
        '-Winit-self',
        '-Wnull-dereference',
        '-Wmaybe-uninitialized',
    ]
    maintainer_cpp_args = [
        '-Wsuggest-final-methods'
    ]

    add_project_arguments(maintainer_c_args, language: 'c')
    add_project_arguments([maintainer_c_args, maintainer_cpp_args], language: 'cpp')
endif

# a few compiler warning/error flags we always want enabled
add_project_arguments(
    '-Werror=shadow',
    '-Werror=empty-body',
    '-Werror=missing-prototypes',
    '-Werror=implicit-function-declaration',
    '-Werror=missing-declarations',
    '-Werror=return-type',
    '-Werror=int-conversion',
    '-Werror=incompatible-pointer-types',
    '-Werror=misleading-indentation',
    '-Werror=format-security',

    '-Wno-missing-field-initializers',
    '-Wno-error=missing-field-initializers',
    '-Wno-unused-parameter',
    '-Wno-error=unused-parameter',
    language: 'c'
)
add_project_arguments(
    cxx.get_supported_arguments([
        '-Werror=empty-body',
        '-Werror=pointer-arith',
        '-Werror=missing-declarations',
        '-Werror=return-type',
        '-Werror=misleading-indentation',
        '-Werror=format-security',
        '-Werror=suggest-override',

        '-Wno-missing-field-initializers',
        '-Wno-error=missing-field-initializers',
        '-Wno-unused-parameter',
        '-Wno-error=unused-parameter',
     ]),
    language: 'cpp'
)

#
# Subdirs
#
subdir('src')
subdir('data')
subdir('tests')
subdir('docs')
