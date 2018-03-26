
conf_data = configuration_data()
conf_data.set('datadir', join_paths(get_option('prefix'), get_option('datadir'), 'appstream'))
conf_data.set('asgen_version', asgen_version)
configure_file(input : 'defines.d.in',
               output: 'defines.d',
               configuration: conf_data
)

#
# Sources
#
asgen_sources = ['../app.d',
    'zarchive.d',
    'bindings/appstream_utils.d',
    'bindings/cairo.d',
    'bindings/freetype.d',
    'bindings/freetypeTypes.d',
    'bindings/fontconfig.d',
    'bindings/pango.d',
    'bindings/gdkpixbuf.d',
    'bindings/libarchive.d',
    'bindings/lmdb.d',
    'bindings/rsvg.d',
    'config.d',
    'contentsstore.d',
    'datastore.d',
    'engine.d',
    'extractor.d',
    'handlers/desktopparser.d',
    'handlers/fonthandler.d',
    'handlers/iconhandler.d',
    'handlers/metainfoparser.d',
    'handlers/metainfovalidator.d',
    'handlers/package.d',
    'handlers/screenshothandler.d',
    'hint.d',
    'font.d',
    'image.d',
    'logging.d',
    'reportgenerator.d',
    'result.d',
    'utils.d',
     join_paths(build_root, 'src', 'asgen', 'defines.d'),
]

backend_sources = [
    'backends/interfaces.d',

    'backends/dummy/package.d',
    'backends/dummy/dummypkg.d',
    'backends/dummy/pkgindex.d',

    'backends/archlinux/package.d',
    'backends/archlinux/alpkg.d',
    'backends/archlinux/alpkgindex.d',
    'backends/archlinux/listfile.d',

    'backends/debian/package.d',
    'backends/debian/debpkg.d',
    'backends/debian/debpkgindex.d',
    'backends/debian/tagfile.d',
    'backends/debian/debutils.d',

    'backends/ubuntu/package.d',
    'backends/ubuntu/ubupkg.d',
    'backends/ubuntu/ubupkgindex.d',

    'backends/rpmmd/package.d',
    'backends/rpmmd/rpmpkg.d',
    'backends/rpmmd/rpmpkgindex.d',
]

#
# Build and test
#
asgen_exe = executable('appstream-generator',
    [asgen_sources,
     backend_sources],
    include_directories: [src_dir,
                          gir_bind_dir],
    dependencies: [dcontainers_dep,
                   glib_dep,
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
    dependencies: [dcontainers_dep,
                   glib_dep,
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
