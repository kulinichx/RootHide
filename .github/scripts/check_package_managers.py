#!/usr/bin/env python3
"""Fail closed if a Sileo-only distribution accidentally bundles Zebra again.
Checks resource files and the selectable manager list, not device behavior.
Use --source REPO, --app Dopamine.app, or --tipa FILE.
"""
import argparse
import pathlib
import plistlib
import sys
import zipfile

FORBIDDEN_FILES = {'zebra.deb', 'license_zebra.md'}
REQUIRED_FILES = {'sileo.deb', 'roothideapp.deb', 'PkgManagers.plist'}


def check_manager_plist(data):
    managers = plistlib.loads(data)
    if not isinstance(managers, list) or len(managers) != 1:
        raise ValueError('PkgManagers.plist must contain exactly the bundled Sileo entry')
    manager = managers[0]
    if not isinstance(manager, dict) or manager.get('Key') != 'org.coolstar.SileoStore':
        raise ValueError('Unexpected selectable package manager')
    if manager.get('Package') != 'sileo.deb' or manager.get('Display Name') != 'Sileo':
        raise ValueError('Sileo package metadata is missing or inconsistent')


def check_names(names):
    names = {name.replace('\\', '/') for name in names}
    for name in names:
        p = pathlib.PurePosixPath(name)
        if p.name.lower() in FORBIDDEN_FILES:
            raise ValueError('Forbidden bundled resource: ' + name)
        if any(part.lower() in {'zebra.app', 'zebra.imageset'} for part in p.parts):
            raise ValueError('Forbidden bundled Zebra directory: ' + name)
        if any(part.lower().endswith('.bak') for part in p.parts):
            raise ValueError('Local backup accidentally bundled: ' + name)
    missing = REQUIRED_FILES - names
    if missing:
        raise ValueError('Missing required root resources: ' + ', '.join(sorted(missing)))


def check_app(app):
    app = pathlib.Path(app)
    if not app.is_dir():
        raise ValueError('App directory does not exist')
    files = [p.relative_to(app).as_posix() for p in app.rglob('*') if p.is_file() or p.is_symlink()]
    check_names(files)
    check_manager_plist((app / 'PkgManagers.plist').read_bytes())


def check_tipa(tipa):
    with zipfile.ZipFile(tipa) as archive:
        prefix = 'Payload/Dopamine.app/'
        files = [n[len(prefix):] for n in archive.namelist() if n.startswith(prefix) and not n.endswith('/')]
        if not files:
            raise ValueError('Payload/Dopamine.app is absent')
        check_names(files)
        check_manager_plist(archive.read(prefix + 'PkgManagers.plist'))


def check_source(repo):
    repo = pathlib.Path(repo)
    app = repo / 'Application' / 'Dopamine'
    check_manager_plist((app / 'UI/PkgManagers/PkgManagers.plist').read_bytes())
    project = (repo / 'Application/Dopamine.xcodeproj/project.pbxproj').read_text(encoding='utf-8-sig')
    for token in ('zebra.deb', 'LICENSE_Zebra.md'):
        if token in project:
            raise ValueError('Retired Xcode resource reference: ' + token)
    if (app / 'Assets.xcassets/Package Managers/Zebra.imageset').exists():
        raise ValueError('Active Zebra asset set still exists')
    bootstrapper = (app / 'Jailbreak/DOBootstrapper.m').read_text(encoding='utf-8-sig')
    for token in ('ZEBRA_SOURCES', 'xyz.willy.Zebra', 'getzbra.com'):
        if token in bootstrapper:
            raise ValueError('Retired Zebra initialization remains: ' + token)
    licenses = (app / 'UI/Settings/DOLicenseViewController.m').read_text(encoding='utf-8-sig')
    if '@"LICENSE_Zebra"' in licenses:
        raise ValueError('Removed bundled license still has a UI entry')
    makefile = (repo / 'Application/Makefile').read_text(encoding='utf-8-sig')
    if '\tcp -a Dopamine/Resources/*.deb ' in makefile:
        raise ValueError('Unfiltered DEB wildcard copy would reintroduce Zebra')
    if 'zebra.deb) continue' not in makefile:
        raise ValueError('Resource-copy Zebra exclusion is absent')
    if 'check_package_managers.py --app' not in makefile:
        raise ValueError('Final app resource check is not connected to packaging')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--source', type=pathlib.Path)
    group.add_argument('--app', type=pathlib.Path)
    group.add_argument('--tipa', type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.source:
            check_source(args.source)
        elif args.app:
            check_app(args.app)
        else:
            check_tipa(args.tipa)
    except (OSError, ValueError, plistlib.InvalidFileException, zipfile.BadZipFile, KeyError) as error:
        print('Package-manager check FAILED: ' + str(error), file=sys.stderr)
        return 1
    print('Package-manager check passed: Sileo present; no bundled Zebra installer or entry.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
