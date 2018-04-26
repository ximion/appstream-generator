project('AppStream Generator', 'd',
    meson_version : '>=0.46',
    subproject_dir : 'contrib/subprojects',
    license : 'LGPL-3.0+',
    version : '0.7.4'
)

asgen_version = meson.project_version()

source_root = meson.source_root()
build_root = meson.build_root()

# Set a few flags to work around compiler bugs
if meson.get_compiler('d').get_id() == 'gcc'
    add_global_arguments(['-Wl,--push-state,-no-as-needed -lcurl -Wl,--pop-state', '-no-pie'], language : 'd')
    add_global_link_arguments('-no-pie', language : 'd')
endif

#
# Dependencies
#
src_dir = include_directories('src/')

dcontainers_dep = dependency('dcontainers', version: '>= 0.8.0', fallback: ['dcontainers', 'dcontainers_dep'])
glib_dep        = dependency('glib-2.0')
gobject_dep     = dependency('gobject-2.0')
gio_dep         = dependency('gio-2.0')
appstream_dep   = dependency('appstream', version : '>= 0.12.0')
lmdb_dep        = dependency('lmdb', version : '>= 0.9')
mustache_dep    = dependency('mustache-d', required: false)
archive_dep     = dependency('libarchive', version : '>= 3.2')
cairo_dep       = dependency('cairo', version : '>= 1.12')
gdkpixbuf_dep   = dependency('gdk-pixbuf-2.0')
rsvg_dep        = dependency('librsvg-2.0')
curl_dep        = dependency('libcurl')
freetype_dep    = dependency('freetype2')
pango_dep       = dependency('pango')
fontconfig_dep  = dependency('fontconfig')

if not mustache_dep.found()
    mustache_sp = subproject('mustache-d')
    mustache_dep = declare_dependency(link_with: mustache_sp.get_variable('mustache_lib'),
        include_directories: mustache_sp.get_variable('src_dir')
    )
endif

#
# Build interfaces from GIR
#
gir_to_d_prog = find_program('girtod')
gir_wrap_dir = source_root + '/contrib/girwrap/'
gir_d_intf_dir = build_root + '/girepo/'

message('Generating D interfaces from GIR...')
girtod_gen = run_command(gir_to_d_prog.path(),
                         '-i', gir_wrap_dir,
                         '-o', gir_d_intf_dir)
if girtod_gen.returncode() != 0
    error('Unable to build D intefaces from GIR:\n' + girtod_gen.stderr() + girtod_gen.stdout())
endif
gir_bind_dir = include_directories('girepo')

# Enlist D GIR interface sources
dgir_glob_script = run_command(source_root + '/contrib/girwrap/find-d-intf-files.py')
if dgir_glob_script.returncode() != 0
    error('Unable to find D GIR interface source code:\n' + dgir_glob_script.stdout() + dgir_glob_script.stderr())
endif
gir_binding_sources = dgir_glob_script.stdout().strip().split('\n')

# static library of bindings automatically generated from GIR
girbind_lib = static_library('girbindings',
    [gir_binding_sources],
    include_directories: [gir_bind_dir]
)

#
# Download JS stuff and additional sources if we couldn't find them
#
if get_option('download-js')
    find_program('yarn') # check for the yarn executable
    message('Downloading JavaScript libraries...')
    if run_command('[', '-d', 'data/templates/default/static/js', ']').returncode() != 0
        getjs_cmd = run_command([source_root + '/contrib/setup/build_js.sh'])
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
