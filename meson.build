project('AppStream Generator', 'cpp',
    meson_version : '>=1.0',
    default_options : ['c_std=c23', 'cpp_std=c++23'],
    subproject_dir : 'contrib/subprojects',
    license : 'LGPL-3.0+',
    version : '0.10.2'
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
appstream_dep = dependency('appstream', version: '>= 1.1.0')
ascompose_dep = dependency('appstream-compose', version: '>= 1.1.0')
lmdb_dep      = dependency('lmdb', version: '>= 0.9.22')
archive_dep   = dependency('libarchive', version: '>= 3.2')
curl_dep      = dependency('libcurl')
fyaml_dep     = dependency('libfyaml', version: '>= 0.8')
tbb_dep       = dependency('tbb')
icu_dep       = dependency('icu-uc')
inja_dep      = dependency('inja', fallback: ['inja', 'inja_dep'], default_options: ['build_tests=false'])
libxml2_dep   = dependency('libxml-2.0') # for rpmmd
catch2_dep    = dependency('catch2-with-main')

backward_deps = []
backward_dep = dependency('', required: false)
if get_option('backward')
    backward_dep  = dependency('backward-cpp', fallback: ['backward-cpp', 'backward_dep'], required: false)
    if backward_dep.found()
        message('Using backward-cpp for stack traces')
        libunwind_dep = dependency('libunwind')
        backward_deps = [backward_dep, libunwind_dep]
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
endif

#
# Compiler flags
#
add_project_arguments('-D_POSIX_C_SOURCE=201710L', language: 'c')
add_project_arguments('-D_POSIX_C_SOURCE=201710L', language: 'cpp')

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
        '-Winline',
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
        #'-Werror=suggest-override', -- we can't enable this, Inja is missing overrides

        '-Wno-missing-field-initializers',
        '-Wno-error=missing-field-initializers',
        '-Wno-unused-parameter',
        '-Wno-error=unused-parameter',
     ]),
    language: 'cpp'
)

#
# Download JS stuff and additional sources if we couldn't find them
#
if get_option('download-js')
    npm_exe = find_program('npm')
    if not fs.is_dir(source_root / 'data' / 'templates' / 'default' / 'static' / 'js')
        message('Downloading JavaScript libraries...')
        getjs_cmd = run_command([source_root + '/contrib/setup/build_js.sh', npm_exe], check: false)
        if getjs_cmd.returncode() != 0
            error('Unable to download JavaScript files with NPM:\n' + getjs_cmd.stdout() + getjs_cmd.stderr())
        endif
    endif
endif

#
# Subdirs
#
subdir('src')
subdir('data')
subdir('tests')
subdir('docs')
