project('AppStream Generator', 'd',
    meson_version : '>=0.40.0',
    subproject_dir : 'contrib/subprojects',
    license : 'LGPL-3.0+',
    version : '0.6.5'
)

asgen_version = meson.project_version()

source_root = meson.source_root()
build_root = meson.build_root()

#
# Sources
#
asgen_sources = ['src/app.d',
    'src/asgen/zarchive.d',
    'src/asgen/bindings/appstream_utils.d',
    'src/asgen/bindings/cairo.d',
    'src/asgen/bindings/freetype.d',
    'src/asgen/bindings/freetypeTypes.d',
    'src/asgen/bindings/fontconfig.d',
    'src/asgen/bindings/pango.d',
    'src/asgen/bindings/gdkpixbuf.d',
    'src/asgen/bindings/libarchive.d',
    'src/asgen/bindings/lmdb.d',
    'src/asgen/bindings/rsvg.d',
    'src/asgen/config.d',
    'src/asgen/contentsstore.d',
    'src/asgen/datastore.d',
    'src/asgen/engine.d',
    'src/asgen/extractor.d',
    'src/asgen/handlers/desktopparser.d',
    'src/asgen/handlers/fonthandler.d',
    'src/asgen/handlers/iconhandler.d',
    'src/asgen/handlers/metainfoparser.d',
    'src/asgen/handlers/metainfovalidator.d',
    'src/asgen/handlers/package.d',
    'src/asgen/handlers/screenshothandler.d',
    'src/asgen/hint.d',
    'src/asgen/font.d',
    'src/asgen/image.d',
    'src/asgen/logging.d',
    'src/asgen/reportgenerator.d',
    'src/asgen/result.d',
    'src/asgen/utils.d',
     join_paths(build_root, 'src', 'asgen', 'defines.d'),
]

backend_sources = [
    'src/asgen/backends/interfaces.d',

    'src/asgen/backends/dummy/package.d',
    'src/asgen/backends/dummy/dummypkg.d',
    'src/asgen/backends/dummy/pkgindex.d',

    'src/asgen/backends/archlinux/package.d',
    'src/asgen/backends/archlinux/alpkg.d',
    'src/asgen/backends/archlinux/alpkgindex.d',
    'src/asgen/backends/archlinux/listfile.d',

    'src/asgen/backends/debian/package.d',
    'src/asgen/backends/debian/debpkg.d',
    'src/asgen/backends/debian/debpkgindex.d',
    'src/asgen/backends/debian/tagfile.d',
    'src/asgen/backends/debian/debutils.d',

    'src/asgen/backends/ubuntu/package.d',
    'src/asgen/backends/ubuntu/ubupkg.d',
    'src/asgen/backends/ubuntu/ubupkgindex.d',

    'src/asgen/backends/rpmmd/package.d',
    'src/asgen/backends/rpmmd/rpmpkg.d',
    'src/asgen/backends/rpmmd/rpmpkgindex.d',
]

#
# Sanitizers & quirk fixes
#

# Set a few flags to work around compiler bugs
if meson.get_compiler('d').get_id() == 'gcc'
    add_global_arguments(['-Wl,--push-state,-no-as-needed -lcurl -Wl,--pop-state', '-no-pie'], language : 'd')
    add_global_link_arguments('-no-pie', language : 'd')
endif
if meson.get_compiler('d').get_id() == 'llvm'
    # work around: https://github.com/ldc-developers/ldc/issues/1727
    add_global_arguments('-enable-cross-module-inlining=false', language : 'd')
endif

# TODO: Make this a real option, not something to manually enable.
#add_global_arguments(['-sanitize=address'], language : 'd')
#add_global_link_arguments('-L-l:libasan.so.4.0.0', language : 'd')

#
# Dependencies
#
src_dir = include_directories('src/')

glib_dep      = dependency('glib-2.0')
gobject_dep   = dependency('gobject-2.0')
gio_dep       = dependency('gio-2.0')
appstream_dep = dependency('appstream', version : '>= 0.10')
lmdb_dep      = dependency('lmdb', version : '>= 0.9')
mustache_dep  = dependency('mustache-d', required: false)
archive_dep   = dependency('libarchive', version : '>= 3.2')
cairo_dep     = dependency('cairo', version : '>= 1.12')
gdkpixbuf_dep = dependency('gdk-pixbuf-2.0')
rsvg_dep      = dependency('librsvg-2.0')
curl_dep      = dependency('libcurl')
freetype_dep  = dependency('freetype2')
pango_dep     = dependency('pango')
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
dgir_glob_script = run_command(source_root + '/contrib/girwrap/find-d-intf-files.sh')
gir_binding_sources = dgir_glob_script.stdout().strip().split('\n')

#
# Download JS stuff and additional sources if we couldn't find them
#

# Download JavaScript assets if requested
download_js = get_option('download_js')
if download_js
    message('Downloading JavaScript libraries...')
    if run_command('[', '-d', 'data/templates/default/static/js', ']').returncode() != 0
        getjs_cmd = run_command([source_root + '/contrib/setup/build_js.sh'])
        if getjs_cmd.returncode() != 0
            error('Unable to download JavaScript files with Bower:\n' + getjs_cmd.stdout() + getjs_cmd.stderr())
        endif
    endif
endif

#
# Build and test
#

subdir('src/asgen')

girbind_lib = static_library('girbindings',
    [gir_binding_sources],
    include_directories: [gir_bind_dir]
)

asgen_exe = executable('appstream-generator',
    [asgen_sources,
     backend_sources],
    include_directories: [src_dir,
                          gir_bind_dir],
    dependencies: [glib_dep,
                   gobject_dep,
                   gio_dep,
                   appstream_dep,
                   lmdb_dep,
                   archive_dep,
                   mustache_dep,
                   cairo_dep,
                   gdkpixbuf_dep,
                   rsvg_dep,
                   curl_dep,
                   freetype_dep,
                   fontconfig_dep,
                   pango_dep],
    link_with: [girbind_lib],
    install: true
)

asgen_test_exe = executable('asgen_test',
    [asgen_sources,
    backend_sources],
    include_directories: [src_dir,
                          gir_bind_dir],
    dependencies: [glib_dep,
                   gobject_dep,
                   gio_dep,
                   appstream_dep,
                   lmdb_dep,
                   archive_dep,
                   mustache_dep,
                   cairo_dep,
                   gdkpixbuf_dep,
                   rsvg_dep,
                   curl_dep,
                   freetype_dep,
                   fontconfig_dep,
                   pango_dep],
    link_with: [girbind_lib],
    d_args: meson.get_compiler('d').unittest_args()
)
test('asgen_tests', asgen_test_exe)

#
# Install
#

# data
install_data('data/asgen-hints.json', install_dir: 'share/appstream')
install_data('data/hicolor-theme-index.theme', install_dir: 'share/appstream')

# templates
#install_subdir('data/templates/', install_dir: 'share/appstream') # FIXME: Doesn't handle dir symlinks correctly
meson.add_install_script(source_root + '/contrib/setup/meson-install-templates.sh')
