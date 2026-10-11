"""Real local HTTP fixture for the compiled raw collector, without broker/schema/media requests."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

binary = str(Path(sys.argv[1]).resolve())
production = str(Path(sys.argv[2]).resolve()) if len(sys.argv) > 2 else None

class Fixture:
    def __init__(self, responses):
        self.responses = responses
        self.paths = []
        fixture = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'
            def do_GET(self):
                fixture.paths.append(self.path)
                index = min(len(fixture.paths)-1, len(fixture.responses)-1)
                response = fixture.responses[index]
                status, body, headers = response[:3]
                self.send_response(status)
                for key, value in headers.items(): self.send_header(key, value)
                if 'Content-Length' not in headers and 'Transfer-Encoding' not in headers:
                    self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    if 'chunked' in headers.get('Transfer-Encoding','').lower():
                        slow = len(response) > 3 and response[3] == 'slow'
                        step = 1 if slow else 17
                        for offset in range(0, len(body), step):
                            if slow: time.sleep(.15)
                            chunk = body[offset:offset+step]
                            self.wfile.write(f'{len(chunk):X}\r\n'.encode()+chunk+b'\r\n')
                            self.wfile.flush()
                        self.wfile.write(b'0\r\n\r\n')
                    else:
                        self.wfile.write(body)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError): pass
                if len(response) > 3 and response[3] == 'truncate':
                    self.close_connection = True
            def log_message(self, *args): pass
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.origin = f'http://127.0.0.1:{self.server.server_port}'
    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
    def __enter__(self): return self
    def __exit__(self, *args): self.close()


def invoke(root, fixture, **options):
    config = {'output': str(root/'out'), 'targets': [fixture.origin],
              'duration_seconds': 2, 'max_requests': 1, 'poll_seconds': 1,
              'timeout_seconds': 1, 'max_response_bytes': 1024,
              'max_archive_bytes': 1024*1024}
    config.update(options)
    path = root/'config.json'
    path.write_text(json.dumps(config))
    run = subprocess.run([binary, '--raw-config', str(path)], capture_output=True, text=True, timeout=15)
    assert run.returncode == 0, (run.returncode, run.stdout, run.stderr)
    return sorted((json.loads(p.read_text()) for p in (root/'out'/'captures').glob('*.json')), key=lambda r:r['sequence'])


def verify(root, record, body):
    stored = (root/'out'/record['body']).read_bytes()
    assert stored == body
    assert record['sha256'] == hashlib.sha256(body).hexdigest()
    assert record['bytes'] == len(body)
    assert record['format'] == 'fediwatch.raw.v1'
    assert record['capture_id'] == f"{record['spool_id']}:{record['sequence']}"
    assert record['observed_at'].endswith('Z') and record['completed_at'].endswith('Z')
    assert 'source_timestamp' not in record and 'ingested_at' not in record


def test_body_and_resume():
    raw = b'[ { "id":"999", "created_at":"1999-01-01T00:00:00Z", "unknown":false, "media_attachments":[{"url":"https://example.invalid/never-fetch"}] }, {"id":"101","nil":null} ]\n'
    with Fixture([(200, raw, {'Content-Type':'application/json','Set-Cookie':'secret=NEVER_COPY','Authorization':'Bearer NEVER_COPY'})]) as f, tempfile.TemporaryDirectory() as d:
        root=Path(d)
        one=invoke(root,f)[0];verify(root,one,raw)
        assert one['cursor_after']=='999' and one['cursor_before']==''
        assert one['complete'] and one['cursor_status']=='cursor_read'
        assert 'NEVER_COPY' not in json.dumps(one)
        time.sleep(1.1)
        records=invoke(root,f)
        assert len(records)==2 and records[1]['cursor_before']=='999'
        assert parse_qs(urlsplit(f.paths[-1]).query)['min_id']==['999']
        assert records[0]['observed_at']==one['observed_at']
        assert all(urlsplit(path).path=='/api/v1/timelines/public' for path in f.paths)
        assert records[1]['capture_id'] != one['capture_id']
        # A body written before a crash has no receipt and cannot advance progress.
        (root/'out/captures/00000000000000000003.body').write_bytes(b'{orphan')
        time.sleep(1.1)
        records=invoke(root,f)
        assert records[-1]['sequence']==4 and records[-1]['cursor_before']=='999'
        # A committed body mismatch fails closed before another network request.
        (root/'out'/one['body']).write_bytes(b'corrupt')
        before=len(f.paths)
        run=subprocess.run([binary,'--raw-config',str(root/'config.json')],capture_output=True,text=True,timeout=5)
        assert run.returncode != 0 and len(f.paths)==before


def test_malformed_and_invalid():
    for body in [b' { malformed\n', b'[{"unknown":true}]', b'{"error":true}', b'[ {"id":"8","timestamp":"invalid"} ]\n']:
        with Fixture([(200,body,{})]) as f, tempfile.TemporaryDirectory() as d:
            root=Path(d);record=invoke(root,f)[0];verify(root,record,body)
            assert record['complete']
            if b'"id":"8"' in body: assert record['cursor_after']=='8'
            else: assert record['cursor_after']=='' and record['cursor_status']=='cursor_unavailable'


def test_http_errors_and_cooldown():
    for status, headers in [(429,{'Retry-After':'120'}),(429,{'Retry-After':'Sun, 11 Oct 2099 12:00:00 GMT'}),
                            (200,{'X-RateLimit-Remaining':'0','Retry-After':'120'}),
                            (401,{}),(403,{}),(404,{}),(503,{})]:
        body=b'[]' if status==200 else b'{"error":"provider"}'
        with Fixture([(status,body,headers)]) as f, tempfile.TemporaryDirectory() as d:
            root=Path(d);records=invoke(root,f,max_requests=2,duration_seconds=1)
            assert len(records)==1
            record=records[0];verify(root,record,body)
            assert record['status']==status and record['cursor_after']==''
            if status in [401,403,404]: assert record['next_poll_at'] > time.time()+86000
            elif status==429 or status==200: assert record['next_poll_at'] > time.time()+100


def test_partial_and_limit():
    for body, headers, suffix in [(b'partial',{'Content-Length':'100'},'truncate'),
                                  (b'x'*2048,{},''),(b'x'*2048,{'Transfer-Encoding':'chunked'},'')]:
        with Fixture([(200,body,headers,suffix)]) as f, tempfile.TemporaryDirectory() as d:
            root=Path(d);record=invoke(root,f,max_response_bytes=100)[0]
            stored=(root/'out'/record['body']).read_bytes()
            assert not record['complete'] and record['cursor_after']==''
            assert len(stored)<=100
            assert record['sha256']==hashlib.sha256(stored).hexdigest()


def test_redirect_and_fairness():
    with Fixture([(200,b'[]',{})]) as destination, Fixture([(302,b'redirect',{'Location':destination.origin+'/secret'})]) as f, tempfile.TemporaryDirectory() as d:
        root=Path(d);record=invoke(root,f)[0];verify(root,record,b'redirect')
        assert record['status']==302 and destination.paths==[]
    with Fixture([(429,b'{}',{'Retry-After':'120'})]) as slow, Fixture([(200,b'[{"id":"1"}]',{})]) as good, tempfile.TemporaryDirectory() as d:
        root=Path(d);records=invoke(root,slow,targets=[slow.origin,good.origin],max_requests=2)
        assert len(records)==2 and len(slow.paths)==len(good.paths)==1


def test_slow_request_deadline():
    with Fixture([(200,b'[{"id":"8"}]',{'Transfer-Encoding':'chunked'},'slow')]) as slow, Fixture([(200,b'[]',{})]) as good, tempfile.TemporaryDirectory() as d:
        root=Path(d);started=time.monotonic()
        records=invoke(root,slow,targets=[slow.origin,good.origin],max_requests=2,duration_seconds=4,timeout_seconds=1)
        elapsed=time.monotonic()-started
        assert len(records)==2 and len(good.paths)==1
        assert not records[0]['complete'] and records[0]['cursor_after']==''
        assert records[1]['complete'] and records[1]['source']==good.origin
        assert elapsed < 2.5, elapsed


def test_resumed_budget_fairness():
    with Fixture([(200,b'[]',{})]) as first, Fixture([(200,b'[]',{})]) as second, tempfile.TemporaryDirectory() as d:
        root=Path(d)
        one=invoke(root,first,targets=[first.origin,second.origin],max_requests=1)
        time.sleep(1.1)
        two=invoke(root,first,targets=[first.origin,second.origin],max_requests=1)
        time.sleep(1.1)
        three=invoke(root,first,targets=[first.origin,second.origin],max_requests=1)
        assert [r['source'] for r in three]==[first.origin,second.origin,first.origin]
        assert len(first.paths)==2 and len(second.paths)==1


def test_unsupported_transfer_framing():
    for encoding in ['Chunked','gzip, chunked']:
        with Fixture([(200,b'[]',{'Transfer-Encoding':encoding,'Connection':'close'})]) as f, tempfile.TemporaryDirectory() as d:
            root=Path(d);record=invoke(root,f)[0]
            assert not record['complete'] and record['cursor_after']==''
            assert record['error']=='unsupported_transfer_encoding'
            assert record['headers']['transfer-encoding']==encoding
            verify(root,record,b'')


def test_config_and_output_safety():
    with Fixture([(200,b'[]',{})]) as f, tempfile.TemporaryDirectory() as d:
        root=Path(d)
        for patch in [{'targets':[]},{'poll_seconds':0},{'limit':41},{'max_requests':False},{'secret':'no'},
                      {'targets':[f.origin+'/path?token=NEVER']},{'targets':['http://user:pass@127.0.0.1']}]:
            config={'output':str(root/'out'),'targets':[f.origin]};config.update(patch)
            p=root/'bad.json';p.write_text(json.dumps(config))
            run=subprocess.run([binary,'--raw-config',str(p)],capture_output=True,text=True,timeout=5)
            assert run.returncode != 0 and 'NEVER' not in run.stderr
        if production:
            for target in [f.origin,'127.0.0.1','[::1]','localhost','x.local','example.com/path','user:pass@example.com']:
                p=root/'bad.json';p.write_text(json.dumps({'output':str(root/'out'),'targets':[target]}))
                run=subprocess.run([production,'--raw-config',str(p)],capture_output=True,text=True,timeout=5)
                assert run.returncode != 0
        assert f.paths==[]
        (root/'repo').mkdir();(root/'repo/.git').mkdir();(root/'repo/.git/HEAD').write_text('ref: refs/heads/main')
        for output in [root/'repo/out',root/'linked']:
            if output.name=='linked': output.symlink_to(root/'repo',target_is_directory=True)
            p=root/'bad.json';p.write_text(json.dumps({'output':str(output),'targets':[f.origin]}))
            run=subprocess.run([binary,'--raw-config',str(p)],capture_output=True,text=True,timeout=5)
            assert run.returncode != 0
        assert f.paths==[]

for test in [test_body_and_resume,test_malformed_and_invalid,test_http_errors_and_cooldown,
             test_partial_and_limit,test_redirect_and_fairness,test_slow_request_deadline,test_resumed_budget_fairness,test_unsupported_transfer_framing,test_config_and_output_safety]:
    test();print(test.__name__+': PASS',flush=True)
print('raw full-response fixture: PASS')
