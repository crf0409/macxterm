#!/usr/bin/env python3
"""Install a verified bundle only after its previous process has exited."""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile


def running_pids(executable):
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    return [int(parts[0]) for line in output.splitlines()
            if len(parts := line.strip().split(maxsplit=1)) == 2 and parts[1] == str(executable)]


def require_stopped(executable):
    if running_pids(executable):
        raise RuntimeError('MacXTerm 仍在运行。请先结束任务并退出应用，再安装；运行期间替换安装文件会使 macOS 沙盒文件选择服务失效。')


def install(source, destination):
    source, destination = pathlib.Path(source).resolve(), pathlib.Path(destination).absolute()
    if source == destination or source.suffix != '.app' or destination.suffix != '.app':
        raise ValueError('来源和目标必须是不同的 .app 目录。')
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.macxterm.MacXTerm' or info.get('CFBundleExecutable') != 'MacXTerm':
        raise ValueError('来源不是正式 MacXTerm 应用。')
    executable = destination / 'Contents/MacOS/MacXTerm'
    require_stopped(executable)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.MacXTerm-install-', dir=destination.parent) as temporary:
        staging = pathlib.Path(temporary) / 'new.app'
        previous = pathlib.Path(temporary) / 'previous.app'
        subprocess.run(['ditto', str(source), str(staging)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staging)], check=True)
        # Copying can take time. Recheck before touching the installed bundle.
        require_stopped(executable)
        if destination.exists(): destination.rename(previous)
        try:
            staging.rename(destination)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(destination)], check=True)
        except BaseException:
            if destination.exists(): shutil.rmtree(destination)
            if previous.exists(): previous.rename(destination)
            raise
    return {'installed': True, 'path': str(destination),
            'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion']}


if __name__ == '__main__':
    root = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=pathlib.Path, default=root / '.build/artifacts/MacXTerm.app')
    parser.add_argument('--destination', type=pathlib.Path, default=pathlib.Path('/Applications/MacXTerm.app'))
    args = parser.parse_args()
    try: print(json.dumps(install(args.source, args.destination), ensure_ascii=False))
    except Exception as error: parser.exit(1, str(error) + '\n')
