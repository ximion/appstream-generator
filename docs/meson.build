# Meson definition for AppStream Generator Documentation

# make manual page
manpages_xsl = 'http://docbook.sourceforge.net/release/xsl-ns/current/manpages/docbook.xsl'
xsltproc = find_program('xsltproc')
if run_command([xsltproc, '--nonet', manpages_xsl],
                check: false).returncode() != 0
    error('Unable to find Docbook XSL stylesheets for man pages.\n' +
          'You may need to install a package named `docbook-xsl-ns` or ' +
          '`docbook5-style-xsl`, depending on your distribution.')
endif

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
        manpages_xsl,
        '@INPUT@'
    ]
)
