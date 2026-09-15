#!/usr/bin/env python3
"""Capture an existing simulator run. Does not install, alter settings, or export credentials."""
import argparse, errno, hashlib, json, os, pathlib, plistlib, shutil, stat, subprocess, time, zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--work-dir', default='.sim/pane-redesign')
parser.add_argument('--bundle-id', default='com.christianselig.Apollo')
parser.add_argument('--base-ipa', default='Apollo-base.ipa')
parser.add_argument('--label', default='capture')
parser.add_argument('--display', help='simctl display name or ID (e.g. resizable for iOS 27 resize sessions)')
parser.add_argument('--command-file', default=os.environ.get('APOLLOFIX_TAP_FILE', '/tmp/apollofix-tap.txt'))
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
out = root / args.work_dir / 'evidence' / (time.strftime('%Y%m%d-%H%M%S-') + pathlib.Path(args.label).name)
out.mkdir(parents=True, exist_ok=True)
def run(*command):
    return subprocess.check_output(command, text=True).strip()

def open_command_file(path):
    flags = os.O_RDWR | getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0)
    created = False
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        if error.errno != errno.ENOENT:
            raise SystemExit('Refusing unsafe simulator command file') from error
        try:
            descriptor = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
            created = True
        except FileExistsError:
            try:
                descriptor = os.open(path, flags)
            except OSError as retry_error:
                raise SystemExit('Refusing unsafe simulator command file') from retry_error
    info = os.fstat(descriptor)
    unsafe_permissions = info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or
            info.st_nlink != 1 or unsafe_permissions):
        os.close(descriptor)
        raise SystemExit('Refusing unsafe simulator command file')
    if info.st_size > 64 * 1024:
        os.close(descriptor)
        raise SystemExit('Refusing oversized simulator command file')
    return descriptor, created, info

def replace_open_file(descriptor, contents):
    os.lseek(descriptor, 0, os.SEEK_SET)
    os.ftruncate(descriptor, 0)
    view = memoryview(contents)
    while view:
        view = view[os.write(descriptor, view):]
    os.fsync(descriptor)

command_file = pathlib.Path(args.command_file)
command_fd, command_created, command_info = open_command_file(command_file)
previous = os.pread(command_fd, command_info.st_size, 0)
try:
    replace_open_file(command_fd, b'panesnapshot')
    command_write_time = os.fstat(command_fd).st_mtime_ns
    subprocess.run(['xcrun','simctl','spawn',args.device,'notifyutil','-p','apollofix.debugtap'],check=True)
    container = pathlib.Path(run('xcrun','simctl','get_app_container',args.device,args.bundle_id,'data'))
    snapshot = container / 'Library/Caches/ApolloPaneSnapshot.json'
    for _ in range(40):
        if snapshot.exists() and snapshot.stat().st_mtime_ns >= command_write_time: break
        time.sleep(.1)
    else: raise SystemExit('No fresh pane snapshot: verify the new tweak is running and main thread is responsive.')
    data = json.loads(snapshot.read_text())
    if data['loadedTweakCopies'] != 1: raise SystemExit('Expected exactly one loaded tweak.')
    shutil.copy2(snapshot, out / 'panes.json')
    display = ['--display=' + args.display] if args.display else []
    subprocess.run(['xcrun','simctl','io',args.device,'screenshot',*display,str(out / 'screen.png')],check=True)
    dylib = root / args.work_dir / 'ApolloReborn.dylib'
    metadata = {'commit':run('git','-C',str(root),'rev-parse','HEAD'),
        'dirtyPaths':run('git','-C',str(root),'status','--short').splitlines(),
        'dylibUUID':run('xcrun','dwarfdump','--uuid',str(dylib)),
        'appearance':run('xcrun','simctl','ui',args.device,'appearance'),
        'textSize':run('xcrun','simctl','ui',args.device,'content_size'),
        'increaseContrast':run('xcrun','simctl','ui',args.device,'increase_contrast'),
        'device':args.device, 'bundleID':args.bundle_id,
        'validation':'Simulator evidence; no device frame-rate or foldable claim.'}
    ipa = root / args.base_ipa
    if ipa.exists():
        metadata['baseIPA_SHA256'] = hashlib.file_digest(ipa.open('rb'), 'sha256').hexdigest()
        with zipfile.ZipFile(ipa) as archive:
            names = [n for n in archive.namelist() if n.startswith('Payload/') and n.count('/') == 2 and n.endswith('.app/Info.plist')]
            info = plistlib.loads(archive.read(names[0]))
            keys = ['CFBundleShortVersionString','CFBundleVersion','UIDeviceFamily','UIRequiresFullScreen',
                'UIApplicationSceneManifest','UISupportedInterfaceOrientations','UISupportedInterfaceOrientations~ipad',
                'UIApplicationSupportsIndirectInputEvents','UILaunchStoryboardName','MinimumOSVersion','DTSDKName']
            metadata['baseBundleMetadata'] = {key:info[key] for key in keys if key in info}
    (out / 'build.json').write_text(json.dumps(metadata,indent=2)+'\n')
    print(out)
finally:
    try:
        current = os.lstat(command_file)
        same_file = (current.st_dev, current.st_ino) == (command_info.st_dev, command_info.st_ino)
    except FileNotFoundError:
        same_file = False
    if command_created:
        if same_file:
            os.unlink(command_file)
    else:
        replace_open_file(command_fd, previous)
    os.close(command_fd)
