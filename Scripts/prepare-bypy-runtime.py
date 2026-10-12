#!/usr/bin/env python3
"""Rebuild the private, relocatable bypy runtime from pinned official artifacts."""
import hashlib, json, pathlib, platform, shutil, subprocess, tarfile, urllib.request, zipfile

root = pathlib.Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'Vendor/ByPy/manifest.json').read_text())
work = root / '.build/bypy'
work.mkdir(parents=True, exist_ok=True)
runtime = work / 'python'
architecture = platform.machine()
asset = manifest['python'][architecture]
archive = work / ('python-' + architecture + '.tar.gz')
if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != asset['sha256']:
    urllib.request.urlretrieve(asset['url'], str(archive))
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == asset['sha256'], 'Python checksum mismatch'
if not (runtime / 'bin/python3').exists():
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            target = (work / member.name).resolve()
            assert work.resolve() in target.parents, 'Unsafe runtime archive path'
        tar.extractall(work)
python = runtime / 'bin/python3'
wheels = work / 'wheels'
wheels.mkdir(exist_ok=True)
lock = root / 'Vendor/ByPy/requirements.lock'
if not lock.exists():
    # Only used by maintainers when creating/updating the committed lock.
    subprocess.run([str(python), '-m', 'pip', 'download', '--dest', str(wheels),
        '--python-version', '39', '--platform', 'any', '--only-binary=:all:', 'bypy==1.8.9'], check=True)
    lines = []
    for wheel in sorted(wheels.glob('*.whl')):
        with zipfile.ZipFile(wheel) as z:
            meta = z.read(next(n for n in z.namelist() if n.endswith('.dist-info/METADATA'))).decode()
        fields = dict(line.split(': ', 1) for line in meta.splitlines() if line.startswith(('Name: ', 'Version: ')))
        lines.append(fields['Name'] + '==' + fields['Version'] + ' --hash=sha256:' + hashlib.sha256(wheel.read_bytes()).hexdigest())
    lock.write_text('\n'.join(lines) + '\n')
else:
    subprocess.run([str(python), '-m', 'pip', 'download', '--dest', str(wheels), '--no-deps',
        '--require-hashes', '--python-version', '39', '--platform', 'any', '--only-binary=:all:',
        '-r', str(lock)], check=True)
packages = work / 'packages'
if packages.exists(): shutil.rmtree(packages)
packages.mkdir()
subprocess.run([str(python), '-m', 'pip', 'install', '--no-deps', '--no-compile', '--require-hashes',
    '--no-index', '--find-links', str(wheels), '--target', str(packages), '-r', str(lock)], check=True)
payload = work / 'packages.zip'
with zipfile.ZipFile(payload, 'w', zipfile.ZIP_DEFLATED) as z:
    for path in sorted(packages.rglob('*')):
        if path.is_file() and '__pycache__' not in path.parts and path.suffix != '.pyc':
            z.write(path, path.relative_to(packages))
(work / 'packages.sha256').write_text(hashlib.sha256(payload.read_bytes()).hexdigest())
shutil.copyfile(root / 'Sources/MacXTermApp/Resources/ByPyBridge.py', work / 'bridge.py')
print('Prepared bypy ' + manifest['bypy_version'] + ' with private Python ' + manifest['python_version'])
