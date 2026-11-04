#!/usr/bin/env python3
"""Capture an existing simulator run. Does not install, alter settings, or export credentials."""
import argparse, hashlib, json, pathlib, plistlib, shutil, subprocess, time, zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--work-dir', default='.sim/pane-redesign')
parser.add_argument('--bundle-id', default='com.christianselig.Apollo')
parser.add_argument('--base-ipa', default='Apollo-base.ipa')
parser.add_argument('--label', default='capture')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
out = root / args.work_dir / 'evidence' / (time.strftime('%Y%m%d-%H%M%S-') + pathlib.Path(args.label).name)
out.mkdir(parents=True, exist_ok=True)
def run(*command):
    return subprocess.check_output(command, text=True).strip()
command_file = pathlib.Path('/tmp/apollofix-tap.txt')
previous = command_file.read_bytes() if command_file.exists() else None
try:
    command_file.write_text('panesnapshot')
    subprocess.run(['xcrun','simctl','spawn',args.device,'notifyutil','-p','apollofix.debugtap'],check=True)
    container = pathlib.Path(run('xcrun','simctl','get_app_container',args.device,args.bundle_id,'data'))
    snapshot = container / 'Library/Caches/ApolloPaneSnapshot.json'
    for _ in range(40):
        if snapshot.exists() and snapshot.stat().st_mtime >= command_file.stat().st_mtime: break
        time.sleep(.1)
    else: raise SystemExit('No fresh pane snapshot: verify the new tweak is running and main thread is responsive.')
    data = json.loads(snapshot.read_text())
    if data['loadedTweakCopies'] != 1: raise SystemExit('Expected exactly one loaded tweak.')
    shutil.copy2(snapshot, out / 'panes.json')
    subprocess.run(['xcrun','simctl','io',args.device,'screenshot',str(out / 'screen.png')],check=True)
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
    if previous is not None: command_file.write_bytes(previous)
    else: command_file.unlink(missing_ok=True)
