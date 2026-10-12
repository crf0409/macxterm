"""MOCK PCS boundary tests using the real pinned bypy implementation; no cloud account."""
import hashlib, importlib.util, io, json, pathlib, tempfile, unittest
from unittest.mock import patch
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / '.build/bypy/packages'))
spec = importlib.util.spec_from_file_location('bridge', ROOT / 'Sources/MacXTermApp/Resources/ByPyBridge.py')
bridge = importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)
import requests, certifi
from bypy import ByPy
from bypy.cached import encrypt_md5
from bypy.requester import RequestsRequester
from requests_toolbelt.multipart.decoder import MultipartDecoder

class MockPCS:
    def __init__(self):
        self.files = {'/apps/bypy/MOCK_中文 file.bin': b'MOCK PCS content\n' * 4096}
        self.slices = {}; self.calls = []; self.directories = set()
    def entry(self, path):
        data = self.files.get(path, b'')
        return dict(path=path, isdir=int(path in self.directories), size=len(data),
            md5=encrypt_md5(hashlib.md5(data).hexdigest()), ctime=1700000000, mtime=1700000000, fs_id=1)
    def request(self, method, url, **kwargs):
        self.calls.append((url, kwargs))
        assert kwargs.get('verify') == certifi.where(), 'TLS verification was weakened'
        params = kwargs.get('params', {})
        operation = params.get('method')
        path = params.get('path', '')
        if isinstance(path, bytes): path = path.decode()
        response = requests.Response(); response.status_code = 200; response.url = url
        if operation == 'list':
            start, end = map(int, params.get('limit', '0-1000').split('-'))
            paths = sorted(p for p in list(self.files) + list(self.directories) if str(pathlib.PurePosixPath(p).parent) == path)
            payload = dict(list=[self.entry(p) for p in paths[start:end]])
        elif operation == 'info': payload = dict(quota=10 * 1024**4, used=128000)
        elif operation == 'download':
            content = self.files[path]
            value = kwargs.get('headers', {}).get('Range', 'bytes=0-')
            start, end = value.split('=')[1].split('-'); content = content[int(start):int(end)+1 if end else None]
            response._content = content; response._content_consumed = True
            return response
        elif operation == 'upload':
            encoder = kwargs['data']
            content_type = kwargs.get('headers', {}).get('Content-Type', getattr(encoder, 'content_type', ''))
            parts = MultipartDecoder(encoder.to_string(), content_type).parts
            data = parts[0].content; digest = hashlib.md5(data).hexdigest()
            if params.get('type') == 'tmpfile': self.slices[digest] = data; payload = dict(md5=digest)
            else: self.files[path] = data; payload = self.entry(path)
        elif operation == 'createsuperfile':
            blocks = json.loads(kwargs['data']['param'])['block_list']
            self.files[path] = b''.join(self.slices[b] for b in blocks); payload = self.entry(path)
        elif operation == 'mkdir': self.directories.add(path); payload = self.entry(path)
        elif operation == 'rapidupload': payload = dict(error_code=31079)
        elif url.endswith(('/auth', '/token')):
            payload = dict(access_token='MOCK_ACCESS_TOKEN', refresh_token='MOCK_REFRESH_TOKEN', expires_in=3600)
        else: raise AssertionError('Unexpected MOCK request: ' + url + ' / ' + str(operation))
        response._content = json.dumps(payload).encode(); response._content_consumed = True
        response.headers['Content-Type'] = 'application/json'
        return response

class ByPyBridgeTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory(prefix='bypy-MOCK-')
        self.root = pathlib.Path(self.folder.name); self.backend = MockPCS()
        self.patch = patch.object(RequestsRequester, 'request', classmethod(lambda cls, method, url, **kw: self.backend.request(method, url, **kw)))
        self.patch.start()
    def tearDown(self): self.patch.stop(); self.folder.cleanup()
    def run_request(self, operation, **kwargs):
        request = dict(operation=operation, configDirectory=str(self.root / 'config'),
            token=json.dumps(dict(access_token='MOCK_ACCESS_TOKEN', refresh_token='MOCK_REFRESH_TOKEN')))
        request.update(kwargs)
        events = []
        bridge.run(request, events.append)
        return events[-1]['result'], events
    def test_list_unicode_paths_and_multiple_api_pages(self):
        for i in range(1005): self.backend.files['/apps/bypy/MOCK_' + str(i) + '.bin'] = b'x'
        result, _ = self.run_request('list')
        self.assertTrue(result['ok']); self.assertEqual(len(result['entries']), 1006)
        self.assertTrue(any(e['name'] == 'MOCK_中文 file.bin' for e in result['entries']))
        self.assertGreaterEqual(len(self.backend.calls), 2)
    def test_chunked_upload_roundtrip_and_progress(self):
        source = self.root / "MOCK_资料 John's.bin"; source.write_bytes(b'MOCK_BINARY_12345' * 200000)
        original_init = ByPy.__init__
        def small_slices(obj, *args, **kwargs):
            kwargs['slice_size'] = 1024 * 1024
            original_init(obj, *args, **kwargs)
        with patch.object(ByPy, '__init__', small_slices):
            uploaded, _ = self.run_request('upload', path='/' + source.name, localPath=str(source))
        self.assertTrue(uploaded['ok'], uploaded)
        self.assertEqual(self.backend.files['/apps/bypy/' + source.name], source.read_bytes())
        self.assertGreaterEqual(len(self.backend.slices), 2)
        destination = self.root / 'MOCK_download.bin'
        downloaded, events = self.run_request('download', path='/' + source.name, localPath=str(destination))
        self.assertTrue(downloaded['ok'], downloaded); self.assertEqual(destination.read_bytes(), source.read_bytes())
        self.assertTrue(any(e['kind'] == 'progress' for e in events))
    def test_collision_preserves_existing_local_and_cloud_files(self):
        source = self.root / 'source.bin'; source.write_bytes(b'changed')
        result, _ = self.run_request('upload', path='/MOCK_中文 file.bin', localPath=str(source))
        self.assertFalse(result['ok']); self.assertNotEqual(self.backend.files['/apps/bypy/MOCK_中文 file.bin'], b'changed')
        destination = self.root / 'existing.bin'; destination.write_bytes(b'keep')
        result, _ = self.run_request('download', path='/MOCK_中文 file.bin', localPath=str(destination))
        self.assertFalse(result['ok']); self.assertEqual(destination.read_bytes(), b'keep')
    def test_authorization_private_update_never_written_to_local_config(self):
        result, _ = self.run_request('authorize', token=None, authorizationCode='MOCK_CODE_01234567890123456789')
        self.assertTrue(result['ok'], result); self.assertIn('MOCK_ACCESS_TOKEN', result['token'])
        self.assertFalse((self.root / 'config/bypy.json').exists())
        for path in (self.root / 'config').rglob('*'):
            if path.is_file(): self.assertNotIn('MOCK_ACCESS_TOKEN', path.read_text())
    def test_unauthed_list_needs_user_handoff_and_makes_no_api_call(self):
        result, _ = self.run_request('list', token=None)
        self.assertTrue(result['needsAuthorization']); self.assertEqual(self.backend.calls, [])
    def test_authorization_failure_does_not_save_a_new_credential(self):
        with patch.object(ByPy, 'info', lambda obj: 150):
            result, _ = self.run_request('authorize', token=None, authorizationCode='MOCK_CODE_01234567890123456789')
        self.assertFalse(result['ok']); self.assertNotIn('token', result)
        self.assertFalse((self.root / 'config/bypy.json').exists())
    def test_invalid_cloud_path_never_accesses_a_parent(self):
        result, _ = self.run_request('list', path='/../outside')
        self.assertFalse(result['ok']); self.assertEqual(self.backend.calls, [])

if __name__ == '__main__': unittest.main(verbosity=2)
