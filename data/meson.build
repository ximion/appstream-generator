
# data
install_data('asgen-hints.json', install_dir: 'share/appstream')
install_data('hicolor-theme-index.theme', install_dir: 'share/appstream')

ascli_exe = find_program('appstreamcli', required: true)

metainfo_filename = 'org.freedesktop.appstream.generator.metainfo.xml'
metainfo_with_relinfo = custom_target('add-metainfo-releases',
    input : ['../NEWS', files(metainfo_filename)],
    output : [metainfo_filename],
    command : [ascli_exe, 'news-to-metainfo', '--limit=6', '@INPUT0@', '@INPUT1@', '@OUTPUT@'],
    install : true,
    install_dir : join_paths (get_option ('datadir'), 'metainfo')
)

if ascli_exe.found()
  # Validate our MetaInfo file
  test('asgen-validate_metainfo',
    ascli_exe,
    args: ['validate',
           '--no-net', '--pedantic',
           files(metainfo_filename)]
  )
endif

# templates
#install_subdir('data/templates/', install_dir: 'share/appstream') # FIXME: Doesn't handle dir symlinks correctly
meson.add_install_script(source_root + '/contrib/setup/meson-install-templates.sh')
