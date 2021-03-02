project('AppStream Generator', 'd',
    meson_version : '>=0.46',
    subproject_dir : 'contrib/subprojects',
    license : 'LGPL-3.0+',
    version : '0.8.5'
)

asgen_version = meson.project_version()

source_root = meson.source_root()
build_root = meson.build_root()

#
# Dependencies
#
src_dir = include_directories('src/')

glibd_dep      = dependency('glibd-2.0')
appstream_dep  = dependency('appstream', version : '>= 0.14.2')
ascompose_dep  = dependency('appstream-compose', version : '>= 0.14.2')
lmdb_dep       = dependency('lmdb', version : '>= 0.9.22')
archive_dep    = dependency('libarchive', version : '>= 3.2')
curl_dep       = dependency('libcurl')

#
# Build interfaces from GIR
#
gir_to_d_prog = find_program('girtod')
gir_wrap_dir = source_root + '/contrib/girwrap/'
gir_d_intf_dir = build_root + '/girepo/'

message('Generating AppStream D interfaces from GIR...')
girtod_gen = run_command(gir_to_d_prog,
                         '-i', gir_wrap_dir,
                         '-o', gir_d_intf_dir,
                         '--print-files', 'relative,' + source_root)
if girtod_gen.returncode() != 0
    error('Unable to build D interfaces from GIR:\n' + girtod_gen.stderr())
endif

gir_bind_dir = include_directories('girepo')
gir_binding_sources = girtod_gen.stdout().strip().split('\n')

# static library of bindings automatically generated from GIR
girbind_lib = static_library('girbindings',
    [gir_binding_sources],
    include_directories: [gir_bind_dir],
    dependencies: [glibd_dep]
)

#
# Download JS stuff and additional sources if we couldn't find them
#
if get_option('download-js')
    yarn_exe = find_program('/usr/share/yarn/bin/yarn', 'yarnpkg') # check for the yarn executable
    message('Downloading JavaScript libraries...')
    if run_command('[', '-d', 'data/templates/default/static/js', ']').returncode() != 0
        getjs_cmd = run_command([source_root + '/contrib/setup/build_js.sh', yarn_exe])
        if getjs_cmd.returncode() != 0
            error('Unable to download JavaScript files with Yarn:\n' + getjs_cmd.stdout() + getjs_cmd.stderr())
        endif
    endif
endif

# asgen sources
subdir('src')

# documentation
subdir('docs')

#data
subdir('data')
