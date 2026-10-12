"""Private NDJSON bridge. Token updates are IPC-only, never user-visible logs."""
import contextlib, fcntl, json, os, pathlib, posixpath, sys, time

ROOT = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'packages'))
CLOUD_ROOT = '/apps/bypy'
_lock_file = None
_lock_directory = None

def normalize(value):
    if not isinstance(value, str) or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError('网盘路径不能包含控制字符。')
    if value == CLOUD_ROOT: value = '/'
    elif value.startswith(CLOUD_ROOT + '/'): value = value[len(CLOUD_ROOT):]
    parts = [p for p in value.split('/') if p not in ('', '.')]
    if '..' in parts: raise ValueError('网盘路径不能包含上级目录跳转。')
    return '/' + '/'.join(parts)

class AuthorizationRequired(Exception): pass
class QuietConsole:
    encoding = 'utf-8'
    def write(self, value): return len(value)
    def flush(self): pass
    def isatty(self): return False

def run(request, emit):
    global _lock_file, _lock_directory
    # All bypy console output is suppressed. Only typed results/progress leave the helper.
    with contextlib.redirect_stdout(QuietConsole()), contextlib.redirect_stderr(QuietConsole()):
        # bypy supports an optional single-process fallback. Named semaphores are
        # forbidden in App Sandbox; transfers are serialized by the native queue.
        sys.modules['multiprocess'] = None
        from bypy import ByPy, const
        import bypy.bypy as module
        from bypy.cached import cached
        from bypy.requester import RequestsRequester
        import certifi
        auth_url = const.ServerAuthUrl + '?' + module.ulp.urlencode({
            'client_id': const.ApiKey, 'response_type': 'code', 'redirect_uri': 'oob', 'scope': 'basic netdisk'})
        config = pathlib.Path(request['configDirectory']).expanduser()
        config.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(config, 0o700)
        os.umask(0o077)
        if _lock_directory != str(config):
            if _lock_file: _lock_file.close()
            _lock_file = (config / 'macxterm.lock').open('a')
            fcntl.flock(_lock_file, fcntl.LOCK_EX)
            _lock_directory = str(config)
        # Isolate caches from any bypy installation the user already uses.
        ByPy.migratesettings = staticmethod(lambda: const.ENoError)
        cached.hashcachepath = str(config / const.HashCacheFileName)
        cached.cache = {}; cached.cacheloaded = False
        (config / const.SettingFileName).write_text(json.dumps({const.SettingKey_LastUpdateCheckTime: int(time.time())}))
        saved_token = request.get('token')
        imported_token = False
        if request.get('persistToken') and (config / const.TokenFileName).exists():
            saved_token = (config / const.TokenFileName).read_text()
        elif request.get('persistToken') and (pathlib.Path.home() / '.bypy' / const.TokenFileName).is_file():
            saved_token = (pathlib.Path.home() / '.bypy' / const.TokenFileName).read_text()
            imported_token = True
        try: token = json.loads(saved_token) if saved_token else {}
        except (TypeError, ValueError): token = {}
        operation = request['operation']
        response = dict(ok=True, authorized=bool(token.get('access_token')), needsAuthorization=False,
            version=const.__version__, authURL=auth_url)
        if operation == 'status':
            emit(dict(kind='result', result=response)); return
        if not token.get('access_token') and operation != 'authorize':
            response.update(authorized=False, needsAuthorization=True)
            emit(dict(kind='result', result=response)); return
        updated_token = None
        def save_token(value):
            path = config / const.TokenFileName
            temporary = path.with_suffix('.new')
            temporary.write_text(value); os.chmod(temporary, 0o600); temporary.replace(path)
        entries = []
        last_progress = [0.0]
        def progress(finish, total, *args, **kwargs):
            now = time.monotonic()
            if now - last_progress[0] >= 0.2 or finish == total:
                last_progress[0] = now
                emit(dict(kind='progress', completed=int(finish), total=int(total)))
        module.pprgr = progress
        module.ask = lambda *a, **k: 'n'
        class VerifiedRequester(RequestsRequester):
            @classmethod
            def request(cls, method, url, **kwargs):
                # Upstream 1.8.9 overrides checkssl=False in its constructor.
                # Override it at the HTTP boundary, including authorization and refresh.
                kwargs['verify'] = certifi.where()
                return super().request(method, url, **kwargs)
        class Client(ByPy):
            def cleanup(self):
                with contextlib.redirect_stdout(QuietConsole()), contextlib.redirect_stderr(QuietConsole()):
                    super().cleanup()
            def _load_local_json(self):
                if operation == 'authorize': return False
                if token.get('access_token'):
                    self._json = token.copy(); self._access_token = token['access_token']; return True
                return False
            def _store_json_only(self, value):
                nonlocal updated_token
                if not value.get('access_token'): return const.ERequestFailed
                self._json = value; self._access_token = value['access_token']
                updated_token = json.dumps(value, ensure_ascii=False)
                if request.get('persistToken') and operation != 'authorize': save_token(updated_token)
                return const.ENoError
            def _auth(self):
                code = request.get('authorizationCode', '').strip()
                if operation != 'authorize' or len(code) < 16: raise AuthorizationRequired()
                module.ask = lambda *a, **k: code
                return super()._auth()
            def _update_auth_server_list(self): pass
            def _proceed_list(self, result, directory, directories, files, args):
                for entry in directories + files:
                    absolute = entry['path']
                    if absolute != CLOUD_ROOT and not absolute.startswith(CLOUD_ROOT + '/'):
                        raise ValueError('网盘返回了应用目录以外的路径。')
                    path = normalize(absolute)
                    entries.append(dict(path=path, name=posixpath.basename(path),
                        isDirectory=bool(entry['isdir']), size=int(entry.get('size', 0)),
                        modified=float(entry.get('mtime', 0))))
                return result
        try:
            client = Client(configdir=str(config), requester=VerifiedRequester, processes=1,
                retry=3, timeout=(10, 60), verify=True, followlink=False, ondup='O')
            cloud_path = normalize(request.get('path', '/'))
            local = os.path.expanduser(request.get('localPath', ''))
            if operation == 'authorize': code = client.info()
            elif operation == 'list': code = client.list(cloud_path)
            elif operation == 'upload':
                if not local or not os.path.exists(local): raise ValueError('要上传的文件或文件夹不存在。')
                # Fail rather than silently replacing an existing cloud file.
                if not request.get('replaceExisting'):
                    exists = client.get_file_info(cloud_path)
                    if exists == 0: raise ValueError('网盘已有同名项目，请确认替换后重试。')
                    if exists != const.EFileNotFound: raise ValueError('无法检查网盘目标是否存在，请重试。')
                code = client.upload(local, cloud_path, ondup='overwrite' if request.get('replaceExisting') else 'newcopy')
            elif operation == 'download':
                if not local: raise ValueError('请选择或填写下载位置。')
                if os.path.exists(local) and not request.get('replaceExisting'):
                    raise ValueError('下载位置已有同名项目，请确认替换后重试。')
                parent = pathlib.Path(local).parent
                if not parent.is_dir(): raise ValueError('下载父目录不存在。')
                if request.get('isDirectory') is None: code = client.download(cloud_path, local)
                else: code = client.downdir(cloud_path, local) if request.get('isDirectory') else client.downfile(cloud_path, local)
            else: raise ValueError('不支持的网盘操作。')
            if code != 0:
                response.update(ok=False, error='bypy 操作失败（代码 {}），请检查授权、网络及网盘路径。'.format(code))
                if code == const.EFileTooBig: response['error'] = '文件超出 bypy 支持的单文件大小范围，请拆分后上传。'
            response['authorized'] = code == 0
            if operation == 'list' and code == 0: response['entries'] = entries
            if code == 0 and imported_token and not updated_token: client._store_json_only(client._json)
            if updated_token and (code == 0 or operation != 'authorize'):
                if request.get('persistToken'): save_token(updated_token)
                else: response['token'] = updated_token
            client.cleanup()
        except AuthorizationRequired:
            response.update(authorized=False, needsAuthorization=True)
        except SystemExit as ex:
            response.update(ok=False, authorized=False, error='bypy 授权或启动失败（代码 {}）。'.format(ex.code))
        except ValueError as ex:
            response.update(ok=False, error=str(ex))
        except Exception:
            response.update(ok=False, error='网盘操作未完成，请检查网络、授权和文件访问权限。')
        emit(dict(kind='result', result=response))

def main():
    output = sys.stdout
    cli = len(sys.argv) > 1
    def emit(event):
        if not cli:
            output.write(json.dumps(event, ensure_ascii=False) + '\n')
        elif event['kind'] == 'progress':
            output.write('\r{} / {} bytes'.format(event.get('completed', 0), event.get('total', 0)))
        elif event['kind'] == 'result':
            result = event['result']
            if result.get('needsAuthorization'): output.write('\n请先在 MacXTerm 百度网盘窗口授权此服务器。\n')
            elif not result['ok']: output.write('\n' + result.get('error', '操作失败') + '\n')
            elif result.get('entries') is not None:
                for entry in result['entries']: output.write(('D ' if entry['isDirectory'] else 'F ') + entry['name'] + '\n')
            else: output.write('\n完成\n')
        output.flush()
    try:
        if cli:
            operation = sys.argv[1]
            if operation not in ('list', 'download', 'upload'):
                output.write('Usage: bypy list [path] | download <path> [destination] | upload <source> [path]\n'); return
            args = sys.argv[2:]
            request = dict(operation=operation, configDirectory=str(ROOT.parent / 'account'), persistToken=True)
            if operation == 'upload':
                request.update(localPath=args[0], path=args[1] if len(args)>1 else '/' + pathlib.Path(args[0]).name)
            else:
                request['path'] = args[0] if args else '/'
                if operation == 'download': request['localPath'] = args[1] if len(args)>1 else posixpath.basename(request['path'])
        else: request = json.loads(sys.stdin.readline(1024 * 1024))
        run(request, emit)
    except Exception:
        emit(dict(kind='result', result=dict(ok=False, authorized=False, needsAuthorization=False,
            version='1.8.9', error='无法初始化 bypy 运行环境。')))

if __name__ == '__main__': main()
