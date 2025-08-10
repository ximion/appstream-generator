project('AppStream Generator', 'cpp',
    meson_version : '>=1.0',
    default_options : ['c_std=c23', 'cpp_std=c++23'],
    subproject_dir : 'contrib/subprojects',
    license : 'LGPL-3.0+',
    version : '0.9.2'
)

asgen_version = meson.project_version()

source_root = meson.project_source_root()
build_root = meson.project_build_root()

fs = import('fs')

#
# Dependencies
#
src_dir = include_directories('src/')

glib_dep      = dependency('glib-2.0', version: '>= 2.80')
appstream_dep = dependency('appstream', version : '>= 1.0.5')
ascompose_dep = dependency('appstream-compose', version : '>= 1.0.5')
lmdb_dep      = dependency('lmdb', version : '>= 0.9.22')
archive_dep   = dependency('libarchive', version : '>= 3.2')
curl_dep      = dependency('libcurl')
fyaml_dep     = dependency('libfyaml', version : '>= 0.8')
inja_dep      = dependency('inja', fallback: ['inja', 'inja_dep'], default_options: ['build_tests=false'])
catch2_dep    = dependency('catch2-with-main')
tbb_dep       = dependency('tbb')

#
# Compiler flags
#
add_project_arguments('-D_POSIX_C_SOURCE=201710L', language: 'c')
add_project_arguments('-D_POSIX_C_SOURCE=201710L', language: 'cpp')

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

# sources
subdir('src')

# documentation
subdir('docs')

# data
subdir('data')

# tests
subdir('tests')
