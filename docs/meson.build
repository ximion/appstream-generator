# Meson definition for AppStream Generator Documentation

# make manual page
xsltproc = find_program('xsltproc')
custom_target('man-asgen',
    input: 'appstream-generator.1.xml',
    output: 'appstream-generator.1',
    install: true,
    install_dir: join_paths(get_option('mandir'), 'man1'),
    command: [
        xsltproc,
        '--nonet',
        '--stringparam', 'man.output.quietly', '1',
        '--stringparam', 'funcsynopsis.style', 'ansi',
        '--stringparam', 'man.th.extra1.suppress', '1',
        '-o', '@OUTPUT@',
        'http://docbook.sourceforge.net/release/xsl/current/manpages/docbook.xsl',
        '@INPUT@'
    ]
)
