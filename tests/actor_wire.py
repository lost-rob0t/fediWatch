"""Run the installed actor through actual HTTP, canonical target and ZeroMQ transport."""
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import ssl
import select
import os
import subprocess
import sys
import threading
import time
import tempfile
from urllib.parse import urlparse, parse_qs
import zmq

root=Path(__file__).resolve().parents[1]
actor_binary=str(Path(sys.argv[1]).resolve())
broker_binary=str(Path(sys.argv[2]).resolve())
account={'id':'42','username':'ada','url':'https://example.test/@ada','display_name':'Ada',
         'note':'<p>Bio</p>','created_at':'2026-10-04T00:00:00.000Z','fields':[],
         'locked':False,'followers_count':7,'unknown':{'flag':False,'nil':None,'items':[]}}
status={'id':'99','account':account,'content':'<p>Exact HTML</p>','url':'https://example.test/@ada/99',
        'created_at':'2026-10-04T00:01:00.000Z','in_reply_to_id':'88',
        'media_attachments':[{'url':'https://example.test/image.png','meta':{'unknown':None}}],
        'tags':[{'name':'hello'}],'sensitive':False,'unknown':{'flag':False,'nil':None,'items':[]}}
invalid={**status,'id':'100','account':{key:value for key,value in account.items() if key!='username'}}
requests=[]
class Mastodon(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_GET(self):
        requests.append(self.path)
        url=urlparse(self.path)
        if url.path=='/.well-known/webfinger':
            body={'subject':'acct:ada@local.test','links':[]}
        elif url.path=='/api/v1/accounts/lookup':
            assert parse_qs(url.query)['acct']==['ada']
            assert self.headers.get('Authorization')=='Bearer fixture-token'
            body=account
        else:
            assert url.path in ['/good/api/v1/timelines/public','/invalid/api/v1/timelines/public'],self.path
            body=[] if 'min_id' in parse_qs(url.query) else [invalid if '/invalid/' in url.path else status]
        payload=json.dumps(body).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(payload)))
        self.end_headers();self.wfile.write(payload)
    def log_message(self,*args):pass
tls_directory=tempfile.TemporaryDirectory()
certificate=Path(tls_directory.name)/'cert.pem'
private_key=Path(tls_directory.name)/'key.pem'
subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                '-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1',
                '-keyout',str(private_key),'-out',str(certificate)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
actor_env={**os.environ,'SSL_CERT_FILE':str(certificate)}
http=ThreadingHTTPServer(('127.0.0.1',0),Mastodon)
tls_context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls_context.load_cert_chain(certificate,private_key)
http.socket=tls_context.wrap_socket(http.socket,server_side=True)
http_thread=threading.Thread(target=http.serve_forever,daemon=True);http_thread.start()
def address():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0));return f'tcp://127.0.0.1:{s.getsockname()[1]}'
pub_address,api_address=address(),address()
context=zmq.Context()
api=context.socket(zmq.DEALER);api.setsockopt(zmq.IDENTITY,b'test-publisher')
api.setsockopt(zmq.RCVTIMEO,5000);api.setsockopt(zmq.SNDTIMEO,5000);api.connect(api_address)
subscriber=context.socket(zmq.SUB)
for topic in (b'user',b'socialmpost',b'relation'):subscriber.setsockopt(zmq.SUBSCRIBE,topic)
subscriber.setsockopt(zmq.RCVTIMEO,10000);subscriber.connect(pub_address)
processes=[]
def stop(process):
    if process.poll() is None:
        process.terminate()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait(timeout=5)
try:
    with tempfile.TemporaryDirectory() as directory:
        broker=subprocess.Popen([broker_binary,'--pubAddress='+pub_address,'--apiAddress='+api_address],
                                stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,cwd=directory)
        processes.append(broker)
        def send(event,payload,topic=b'fediwatch'):
            api.send_multipart([b'',b'SC01',b'test-publisher',b'wire:test',str(int(time.time())).encode(),
                                str(event).encode(),topic,payload.encode()])
            return api.recv_multipart()
        assert send(7,'',b'test')==[b'1']
        actor=subprocess.Popen([actor_binary,'--apiAddress='+api_address,'--subAddress='+pub_address],
                               stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=directory,env=actor_env)
        processes.append(actor)
        ready,_,_=select.select([actor.stdout],[],[],15)
        assert ready,'actor did not report a broker connection'
        assert actor.stdout.readline().decode().strip()=='FediWatch connected to StarRouter'
        time.sleep(.3)
        target={'id':'target:good','dataset':'test','dtype':'target','schemaVersion':'0.10.1','actor':'fediwatch',
                'target':f'https://127.0.0.1:{http.server_port}/good','options':{'typ':'Domain','opaque':{'flag':False,'nil':None}}}
        assert send(8,json.dumps(target))==[b'1']
        documents=[json.loads(subscriber.recv_multipart()[-1]) for _ in range(3)]
        assert {d['dtype'] for d in documents}=={'user','socialmpost','relation'}
        by_type={d['dtype']:d for d in documents}
        user,post,relation=by_type['user'],by_type['socialmpost'],by_type['relation']
        assert all(d['schemaVersion']=='0.10.1' and d['dataset']=='test' and 'id' in d and '_id' not in d for d in documents)
        assert user['raw']==account and post['raw']==status
        assert user['username']=='ada' and user['platform']=='fediverse' and user['private'] is False
        assert user['id']==hashlib.md5((account['username']+account['url']).encode()).hexdigest()
        assert post['id']==hashlib.md5(status['id'].encode()).hexdigest()
        assert post['content']==status['content'] and post['sensitive'] is False and post['hashtags']==['hello']
        assert post['user']=={'schema':'org.starintel/core@1/user','id':user['id']}
        assert relation['source']==post['user']
        assert relation['destination']=={'schema':'org.starintel/core@1/socialmpost','id':post['id']}
        assert relation['predicate']=='org.starintel/core@1/owns'
        assert 'media' not in post and 'replyTo' not in post,'unresolved raw values must not become invented references'
        assert any(path.startswith('/good/api/') for path in requests)
        assert not subscriber.poll(1500),'duplicate timeline publication'
        user_target={**target,'id':'target:user','target':f'ada@127.0.0.1:{http.server_port}',
                     'options':{'typ':'User','auth':'fixture-token'}}
        for _ in range(2):
            assert send(8,json.dumps(user_target))==[b'1']
            observed=json.loads(subscriber.recv_multipart()[-1])
            assert observed==user,'cached user lookup changed canonical projection'
        assert len([path for path in requests if path.startswith('/api/v1/accounts/lookup')])==1
        assert len([path for path in requests if path.startswith('/.well-known/webfinger')])==1
        target['id']='target:invalid';target['target']=f'https://127.0.0.1:{http.server_port}/invalid'
        assert send(8,json.dumps(target))==[b'1']
        deadline=time.monotonic()+5
        while not any(path.startswith('/invalid/api/') for path in requests):
            assert actor.poll() is None
            assert time.monotonic()<deadline,'invalid observation was not fetched'
            time.sleep(.05)
        assert not subscriber.poll(1000),'invalid observation produced a partial document'
        assert actor.poll() is None,'actor should retain its retry loop after invalid input'
        assert send(8,json.dumps({**target,'schemaVersion':'0.10.2'}))==[b'2']
    print('actual installed actor: generated target, verified HTTPS timeline and authenticated cached account lookup, validated user/post/relation, stable identities, lossless raw values, valid references, invalid observation no partial publication PASS')
finally:
    for process in reversed(processes):stop(process)
    api.close(linger=0);subscriber.close(linger=0);context.term()
    http.shutdown();http.server_close();http_thread.join(timeout=5);tls_directory.cleanup()
