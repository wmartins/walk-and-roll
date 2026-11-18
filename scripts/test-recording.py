#!/usr/bin/env python3
"""Run recording tests with the same SDK preference as the local app build."""
import os
from pathlib import Path
import shutil
import subprocess
import sys


def copy_if_changed(source, destination):
    source_info = Path(source).stat()
    target = Path(destination)
    if target.exists():
        target_info = target.stat()
        if (source_info.st_size, source_info.st_mtime_ns) == (target_info.st_size, target_info.st_mtime_ns):
            return destination
    return shutil.copy2(source, destination)


def main():
    root = Path(__file__).resolve().parent.parent
    probe = subprocess.run(
        ['xcrun', '--sdk', 'macosx26.5', '--show-sdk-path'], capture_output=True, text=True
    )
    sdk = probe.stdout.strip() if probe.returncode == 0 else subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True
    ).strip()
    environment = os.environ.copy()
    environment['SDKROOT'] = sdk
    environment['CLANG_MODULE_CACHE_PATH'] = str(root / 'build' / 'ModuleCache')
    environment['SWIFT_MODULECACHE_PATH'] = str(root / 'build' / 'ModuleCache')
    # Some CLT installs pair current runtime libraries with stale private
    # interfaces. Use a local copy of their public interfaces in that case.
    toolchain = Path(subprocess.check_output(['xcrun', '--find', 'swift'], text=True).strip()).parent.parent
    runtime = toolchain / 'lib' / 'swift' / 'pm'
    private_interfaces = list((runtime / 'ManifestAPI').rglob('*.private.swiftinterface'))
    stale = any(
        path.with_name(path.name.replace('.private.swiftinterface', '.swiftinterface')).exists()
        and path.read_text().splitlines()[1] != path.with_name(
            path.name.replace('.private.swiftinterface', '.swiftinterface')
        ).read_text().splitlines()[1]
        for path in private_interfaces
    )
    if stale:
        local_runtime = root / 'build' / 'swiftpm-runtime'
        for name in ['ManifestAPI', 'PluginAPI']:
            shutil.copytree(runtime / name, local_runtime / name, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns('*.private.swiftinterface'), copy_function=copy_if_changed)
        environment['SWIFTPM_CUSTOM_LIBS_DIR'] = str(local_runtime)
    macro_arguments = []
    for relative in ['lib/swift/host/plugins/testing/libTestingMacros.dylib',
                     'lib/swift/host/plugins/libTestingMacros.dylib']:
        plugin = toolchain / relative
        if plugin.exists():
            macro_arguments = ['-Xswiftc', '-load-plugin-library', '-Xswiftc', str(plugin)]
            break
    return subprocess.run([
        'swift', 'test', '--package-path', str(root), '--sdk', sdk,
        '--scratch-path', str(root / 'build' / 'tests'),
        '--cache-path', str(root / 'build' / 'swiftpm-cache'),
        '--config-path', str(root / 'build' / 'swiftpm-config'),
        '--security-path', str(root / 'build' / 'swiftpm-security'),
        '--manifest-cache', 'local', '--disable-xctest', '--enable-swift-testing',
        '--no-parallel', '--configuration', 'release', *macro_arguments, *sys.argv[1:],
    ], env=environment).returncode


if __name__ == '__main__':
    sys.exit(main())
