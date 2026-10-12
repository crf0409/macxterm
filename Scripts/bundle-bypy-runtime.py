#!/usr/bin/env python3
"""Bundle and individually sign Python code before sealing the enclosing app."""
import os, pathlib, shutil, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'Scripts/prepare-bypy-runtime.py')], check=True)
source = root / '.build/bypy'
destination = pathlib.Path(sys.argv[1])
if destination.exists(): shutil.rmtree(destination)
destination.mkdir(parents=True)
shutil.copytree(source / 'python', destination / 'python', symlinks=True)
shutil.copytree(source / 'packages', destination / 'packages')
shutil.copyfile(source / 'packages.zip', destination / 'packages.zip')
shutil.copyfile(root / 'Sources/MacXTermApp/Resources/ByPyBridge.py', destination / 'bridge.py')
shutil.copyfile(root / 'Vendor/ByPy/LICENSE', destination / 'BYPY-LICENSE.txt')
identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-'
magic = [b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe']
for path in sorted((destination / 'python').rglob('*')):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as f: header = f.read(4)
        if header in magic:
            command = ['codesign', '--force', '--sign', identity]
            if path.name.startswith('python3'):
                command += ['--entitlements', str(root / 'Config/ByPyHelper.entitlements')]
            subprocess.run(command + [str(path)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print('Bundled sandbox-inheriting bypy runtime')
