project('AppStream Generator', 'd')

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
    'src/asgen/bindings/concurrency_generator.d',
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
    'src/asgen/utils.d'
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

gir_binding_sources = [
    'src/girepo/appstream/Bundle.d',
    'src/girepo/appstream/Category.d',
    'src/girepo/appstream/Checksum.d',
    'src/girepo/appstream/Component.d',
    'src/girepo/appstream/Pool.d',
    'src/girepo/appstream/DistroDetails.d',
    'src/girepo/appstream/Icon.d',
    'src/girepo/appstream/Image.d',
    'src/girepo/appstream/Metadata.d',
    'src/girepo/appstream/Provided.d',
    'src/girepo/appstream/Release.d',
    'src/girepo/appstream/Screenshot.d',
    'src/girepo/appstream/Translation.d',
    'src/girepo/appstream/Validator.d',
    'src/girepo/appstream/ValidatorIssue.d',
    'src/girepo/appstream/Suggested.d',
    'src/girepo/gi/appstream.d',
    'src/girepo/gi/appstreamtypes.d',
    'src/girepo/gi/gio.d',
    'src/girepo/gi/giotypes.d',
    'src/girepo/gi/glib.d',
    'src/girepo/gi/glibtypes.d',
    'src/girepo/gi/gobject.d',
    'src/girepo/gi/gobjecttypes.d',
    'src/girepo/gio/Action.d',
    'src/girepo/gio/ActionGroup.d',
    'src/girepo/gio/ActionGroupIF.d',
    'src/girepo/gio/ActionGroupT.d',
    'src/girepo/gio/ActionIF.d',
    'src/girepo/gio/ActionMapIF.d',
    'src/girepo/gio/ActionMapT.d',
    'src/girepo/gio/ActionT.d',
    'src/girepo/gio/AppInfo.d',
    'src/girepo/gio/AppInfoIF.d',
    'src/girepo/gio/AppInfoMonitor.d',
    'src/girepo/gio/AppInfoT.d',
    'src/girepo/gio/AppLaunchContext.d',
    'src/girepo/gio/ApplicationCommandLine.d',
    'src/girepo/gio/Application.d',
    'src/girepo/gio/AsyncInitableIF.d',
    'src/girepo/gio/AsyncInitableT.d',
    'src/girepo/gio/AsyncResultIF.d',
    'src/girepo/gio/AsyncResultT.d',
    'src/girepo/gio/BufferedInputStream.d',
    'src/girepo/gio/BufferedOutputStream.d',
    'src/girepo/gio/BytesIcon.d',
    'src/girepo/gio/Cancellable.d',
    'src/girepo/gio/CharsetConverter.d',
    'src/girepo/gio/ContentType.d',
    'src/girepo/gio/Converter.d',
    'src/girepo/gio/ConverterIF.d',
    'src/girepo/gio/ConverterInputStream.d',
    'src/girepo/gio/ConverterOutputStream.d',
    'src/girepo/gio/ConverterT.d',
    'src/girepo/gio/Credentials.d',
    'src/girepo/gio/DatagramBasedIF.d',
    'src/girepo/gio/DataOutputStream.d',
    'src/girepo/gio/DBusActionGroup.d',
    'src/girepo/gio/DBusAnnotationInfo.d',
    'src/girepo/gio/DBusArgInfo.d',
    'src/girepo/gio/DBusAuthObserver.d',
    'src/girepo/gio/DBusConnection.d',
    'src/girepo/gio/DBusError.d',
    'src/girepo/gio/DBusInterface.d',
    'src/girepo/gio/DBusInterfaceIF.d',
    'src/girepo/gio/DBusInterfaceInfo.d',
    'src/girepo/gio/DBusInterfaceSkeleton.d',
    'src/girepo/gio/DBusInterfaceT.d',
    'src/girepo/gio/DBusMenuModel.d',
    'src/girepo/gio/DBusMessage.d',
    'src/girepo/gio/DBusMethodInfo.d',
    'src/girepo/gio/DBusMethodInvocation.d',
    'src/girepo/gio/DBusNames.d',
    'src/girepo/gio/DBusNodeInfo.d',
    'src/girepo/gio/DBusObject.d',
    'src/girepo/gio/DBusObjectIF.d',
    'src/girepo/gio/DBusObjectManagerClient.d',
    'src/girepo/gio/DBusObjectManagerIF.d',
    'src/girepo/gio/DBusObjectManagerServer.d',
    'src/girepo/gio/DBusObjectManagerT.d',
    'src/girepo/gio/DBusObjectProxy.d',
    'src/girepo/gio/DBusObjectSkeleton.d',
    'src/girepo/gio/DBusObjectT.d',
    'src/girepo/gio/DBusPropertyInfo.d',
    'src/girepo/gio/DBusProxy.d',
    'src/girepo/gio/DBusServer.d',
    'src/girepo/gio/DBusSignalInfo.d',
    'src/girepo/gio/DBusUtilities.d',
    'src/girepo/gio/DesktopAppInfo.d',
    'src/girepo/gio/DesktopAppInfoLookupIF.d',
    'src/girepo/gio/DesktopAppInfoLookupT.d',
    'src/girepo/gio/Drive.d',
    'src/girepo/gio/DriveIF.d',
    'src/girepo/gio/DriveT.d',
    'src/girepo/gio/Emblem.d',
    'src/girepo/gio/EmblemedIcon.d',
    'src/girepo/gio/ErrorGIO.d',
    'src/girepo/gio/FileAttributeInfoList.d',
    'src/girepo/gio/FileAttributeMatcher.d',
    'src/girepo/gio/File.d',
    'src/girepo/gio/FileDescriptorBasedIF.d',
    'src/girepo/gio/FileDescriptorBasedT.d',
    'src/girepo/gio/FileEnumerator.d',
    'src/girepo/gio/FileIcon.d',
    'src/girepo/gio/FileIF.d',
    'src/girepo/gio/FileInfo.d',
    'src/girepo/gio/FileInputStream.d',
    'src/girepo/gio/FileIOStream.d',
    'src/girepo/gio/FileMonitor.d',
    'src/girepo/gio/FilenameCompleter.d',
    'src/girepo/gio/FileOutputStream.d',
    'src/girepo/gio/FileT.d',
    'src/girepo/gio/FilterInputStream.d',
    'src/girepo/gio/FilterOutputStream.d',
    'src/girepo/gio/Icon.d',
    'src/girepo/gio/IconIF.d',
    'src/girepo/gio/IconT.d',
    'src/girepo/gio/InitableIF.d',
    'src/girepo/gio/InitableT.d',
    'src/girepo/gio/InputStream.d',
    'src/girepo/gio/IOExtension.d',
    'src/girepo/gio/IOExtensionPoint.d',
    'src/girepo/gio/IOSchedulerJob.d',
    'src/girepo/gio/IOStream.d',
    'src/girepo/gio/ListModelIF.d',
    'src/girepo/gio/ListModelT.d',
    'src/girepo/gio/ListStore.d',
    'src/girepo/gio/LoadableIconIF.d',
    'src/girepo/gio/LoadableIconT.d',
    'src/girepo/gio/MemoryInputStream.d',
    'src/girepo/gio/MemoryOutputStream.d',
    'src/girepo/gio/MenuAttributeIter.d',
    'src/girepo/gio/Menu.d',
    'src/girepo/gio/MenuItem.d',
    'src/girepo/gio/MenuLinkIter.d',
    'src/girepo/gio/MenuModel.d',
    'src/girepo/gio/Mount.d',
    'src/girepo/gio/MountIF.d',
    'src/girepo/gio/MountOperation.d',
    'src/girepo/gio/MountT.d',
    'src/girepo/gio/NativeVolumeMonitor.d',
    'src/girepo/gio/Notification.d',
    'src/girepo/gio/OutputStream.d',
    'src/girepo/gio/Permission.d',
    'src/girepo/gio/PollableInputStreamIF.d',
    'src/girepo/gio/PollableInputStreamT.d',
    'src/girepo/gio/PollableOutputStreamIF.d',
    'src/girepo/gio/PollableOutputStreamT.d',
    'src/girepo/gio/PollableUtils.d',
    'src/girepo/gio/PropertyAction.d',
    'src/girepo/gio/ProxyResolver.d',
    'src/girepo/gio/ProxyResolverIF.d',
    'src/girepo/gio/ProxyResolverT.d',
    'src/girepo/gio/RemoteActionGroupIF.d',
    'src/girepo/gio/RemoteActionGroupT.d',
    'src/girepo/gio/Resource.d',
    'src/girepo/gio/SeekableIF.d',
    'src/girepo/gio/SeekableT.d',
    'src/girepo/gio/Settings.d',
    'src/girepo/gio/SettingsSchema.d',
    'src/girepo/gio/SettingsSchemaKey.d',
    'src/girepo/gio/SettingsSchemaSource.d',
    'src/girepo/gio/SimpleAction.d',
    'src/girepo/gio/SimpleActionGroup.d',
    'src/girepo/gio/SimpleAsyncResult.d',
    'src/girepo/gio/SimpleIOStream.d',
    'src/girepo/gio/SimplePermission.d',
    'src/girepo/gio/SimpleProxyResolver.d',
    'src/girepo/gio/SocketControlMessage.d',
    'src/girepo/gio/SrvTarget.d',
    'src/girepo/gio/StaticResource.d',
    'src/girepo/gio/Subprocess.d',
    'src/girepo/gio/SubprocessLauncher.d',
    'src/girepo/gio/Task.d',
    'src/girepo/gio/TestDBus.d',
    'src/girepo/gio/ThemedIcon.d',
    'src/girepo/gio/TlsFileDatabaseIF.d',
    'src/girepo/gio/TlsFileDatabaseT.d',
    'src/girepo/gio/TlsPassword.d',
    'src/girepo/gio/UnixCredentialsMessage.d',
    'src/girepo/gio/UnixFDList.d',
    'src/girepo/gio/UnixFDMessage.d',
    'src/girepo/gio/UnixInputStream.d',
    'src/girepo/gio/UnixMountEntry.d',
    'src/girepo/gio/UnixMountMonitor.d',
    'src/girepo/gio/UnixMountPoint.d',
    'src/girepo/gio/UnixOutputStream.d',
    'src/girepo/gio/Vfs.d',
    'src/girepo/gio/Volume.d',
    'src/girepo/gio/VolumeIF.d',
    'src/girepo/gio/VolumeMonitor.d',
    'src/girepo/gio/VolumeT.d',
    'src/girepo/gio/ZlibCompressor.d',
    'src/girepo/gio/ZlibDecompressor.d',
    'src/girepo/glib/ArrayG.d',
    'src/girepo/glib/AsyncQueue.d',
    'src/girepo/glib/Atomic.d',
    'src/girepo/glib/Base64.d',
    'src/girepo/glib/BBTree.d',
    'src/girepo/glib/BookmarkFile.d',
    'src/girepo/glib/ByteArray.d',
    'src/girepo/glib/Bytes.d',
    'src/girepo/glib/CharacterSet.d',
    'src/girepo/glib/Checksum.d',
    'src/girepo/glib/Child.d',
    'src/girepo/glib/Cond.d',
    'src/girepo/glib/ConstructionException.d',
    'src/girepo/glib/DataList.d',
    'src/girepo/glib/DataSet.d',
    'src/girepo/glib/Date.d',
    'src/girepo/glib/DateTime.d',
    'src/girepo/glib/Directory.d',
    'src/girepo/glib/ErrorG.d',
    'src/girepo/glib/FileUtils.d',
    'src/girepo/glib/GException.d',
    'src/girepo/glib/GLib.d',
    'src/girepo/glib/HashTable.d',
    'src/girepo/glib/HashTableIter.d',
    'src/girepo/glib/Hmac.d',
    'src/girepo/glib/Hook.d',
    'src/girepo/glib/HookList.d',
    'src/girepo/glib/Hostname.d',
    'src/girepo/glib/IConv.d',
    'src/girepo/glib/Idle.d',
    'src/girepo/glib/Internationalization.d',
    'src/girepo/glib/IOChannel.d',
    'src/girepo/glib/KeyFile.d',
    'src/girepo/glib/ListG.d',
    'src/girepo/glib/ListSG.d',
    'src/girepo/glib/MainContext.d',
    'src/girepo/glib/MainLoop.d',
    'src/girepo/glib/MappedFile.d',
    'src/girepo/glib/MatchInfo.d',
    'src/girepo/glib/Memory.d',
    'src/girepo/glib/MemorySlice.d',
    'src/girepo/glib/MessageLog.d',
    'src/girepo/glib/Messages.d',
    'src/girepo/glib/Mutex.d',
    'src/girepo/glib/Node.d',
    'src/girepo/glib/Once.d',
    'src/girepo/glib/OptionContext.d',
    'src/girepo/glib/OptionGroup.d',
    'src/girepo/glib/Pattern.d',
    'src/girepo/glib/Private.d',
    'src/girepo/glib/PtrArray.d',
    'src/girepo/glib/Quark.d',
    'src/girepo/glib/QueueG.d',
    'src/girepo/glib/RandG.d',
    'src/girepo/glib/RecMutex.d',
    'src/girepo/glib/Regex.d',
    'src/girepo/glib/RWLock.d',
    'src/girepo/glib/ScannerG.d',
    'src/girepo/glib/Sequence.d',
    'src/girepo/glib/SequenceIter.d',
    'src/girepo/glib/ShellUtils.d',
    'src/girepo/glib/SimpleXML.d',
    'src/girepo/glib/Source.d',
    'src/girepo/glib/Spawn.d',
    'src/girepo/glib/Str.d',
    'src/girepo/glib/StringChunk.d',
    'src/girepo/glib/StringG.d',
    'src/girepo/glib/TestLogBuffer.d',
    'src/girepo/glib/TestLogMsg.d',
    'src/girepo/glib/TestSuite.d',
    'src/girepo/glib/Thread.d',
    'src/girepo/glib/ThreadPool.d',
    'src/girepo/glib/Timeout.d',
    'src/girepo/glib/Timer.d',
    'src/girepo/glib/TimeVal.d',
    'src/girepo/glib/TimeZone.d',
    'src/girepo/glib/TrashStack.d',
    'src/girepo/glib/Unicode.d',
    'src/girepo/glib/UnixUtils.d',
    'src/girepo/glib/URI.d',
    'src/girepo/glib/Util.d',
    'src/girepo/glib/VariantBuilder.d',
    'src/girepo/glib/Variant.d',
    'src/girepo/glib/VariantDict.d',
    'src/girepo/glib/VariantIter.d',
    'src/girepo/glib/VariantType.d',
    'src/girepo/glib/Version.d',
    'src/girepo/gobject/Binding.d',
    'src/girepo/gobject/Boxed.d',
    'src/girepo/gobject/CClosure.d',
    'src/girepo/gobject/Closure.d',
    'src/girepo/gobject/Enums.d',
    'src/girepo/gobject/Flags.d',
    'src/girepo/gobject/ObjectClass.d',
    'src/girepo/gobject/ObjectG.d',
    'src/girepo/gobject/ParamSpec.d',
    'src/girepo/gobject/ParamSpecPool.d',
    'src/girepo/gobject/Signals.d',
    'src/girepo/gobject/TypeClass.d',
    'src/girepo/gobject/Type.d',
    'src/girepo/gobject/TypeInstance.d',
    'src/girepo/gobject/TypeInterface.d',
    'src/girepo/gobject/TypeModule.d',
    'src/girepo/gobject/TypePlugin.d',
    'src/girepo/gobject/TypePluginIF.d',
    'src/girepo/gobject/TypePluginT.d',
    'src/girepo/gobject/TypeValueTable.d',
    'src/girepo/gobject/ValueArray.d',
    'src/girepo/gobject/Value.d',
    'src/girepo/gobject/WeakRef.d'
]

# FIXME: including 'src/girepo/gio/DataInputStream.d' in the
# build process results in linker errors. Investigate why.

#
# Dependencies
#
src_dir = include_directories('src/')
gir_bind_dir = include_directories('src/girepo/')

glib_dep      = dependency('glib-2.0')
gobject_dep   = dependency('gobject-2.0')
gio_dep       = dependency('gio-2.0')
appstream_dep = dependency('appstream', version : '>= 0.10')
lmdb_dep      = dependency('lmdb', version : '>= 0.9')
archive_dep   = dependency('libarchive', version : '>= 3.2')
cairo_dep     = dependency('cairo', version : '>= 1.12')
gdkpixbuf_dep = dependency('gdk-pixbuf-2.0')
rsvg_dep      = dependency('librsvg-2.0')
curl_dep      = dependency('libcurl')
freetype_dep  = dependency('freetype2')
pango_dep     = dependency('pango')
fontconfig_dep  = dependency('fontconfig')

# A couple of hacks to use the right copy of mustache-d
mustache_d_file = '/usr/include/d/mustache-d/mustache.d'
mustache_dir = include_directories('/usr/include/d/mustache-d')
if run_command('[', '-e', mustache_d_file, ']').returncode() != 0
    mustached_src_dir = build_root + '/3rd-party/mustache-d'
    if run_command('[', '-d', mustached_src_dir, ']').returncode() != 0
        message('Fetching Mustache-D from Github...')
        git_get_requests = run_command(['git', 'clone', 'https://github.com/repeatedly/mustache-d.git', mustached_src_dir])
        if git_get_requests.returncode() != 0
            error('Unable to fetch Mustache-D:\n' + git_get_requests.stderr())
        endif
    endif
    mustache_d_file = mustached_src_dir + '/src/mustache.d'
    mustache_dir = include_directories(mustached_src_dir + '/src')
endif
mustache_sources = [mustache_d_file]

# Set a few flags to work around compiler bugs
if meson.get_compiler('d').get_id() == 'gcc'
    add_global_arguments('-Wl,--push-state,-no-as-needed -lcurl -Wl,--pop-state', language : 'd')
endif
if meson.get_compiler('d').get_id() == 'llvm'
    # work around: https://github.com/ldc-developers/ldc/issues/1727
    add_global_arguments('-enable-cross-module-inlining=false', language : 'd')
endif

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
asgen_exe = executable('appstream-generator',
    [asgen_sources,
     backend_sources,
     gir_binding_sources,
     mustache_sources],
    include_directories: [src_dir,
                          gir_bind_dir,
                          mustache_dir],
    dependencies: [glib_dep,
                   gobject_dep,
                   gio_dep,
                   appstream_dep,
                   lmdb_dep,
                   archive_dep,
                   cairo_dep,
                   gdkpixbuf_dep,
                   rsvg_dep,
                   curl_dep,
                   freetype_dep,
                   fontconfig_dep,
                   pango_dep],
    install: true
)

asgen_test_exe = executable('asgen_test',
    [asgen_sources,
    backend_sources,
    gir_binding_sources,
    mustache_sources],
    include_directories: [src_dir,
                          gir_bind_dir,
                          mustache_dir],
    dependencies: [glib_dep,
                   gobject_dep,
                   gio_dep,
                   appstream_dep,
                   lmdb_dep,
                   archive_dep,
                   cairo_dep,
                   gdkpixbuf_dep,
                   rsvg_dep,
                   curl_dep,
                   freetype_dep,
                   fontconfig_dep,
                   pango_dep],
    d_args : meson.get_compiler('d').unittest_args()
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
