"""Spawn only synthetic loopback subprocesses: media, v1 backup, crash and restore."""
import argparse, base64, hashlib, json, os, re, shutil, socket, sqlite3, struct, subprocess, tempfile, time, urllib.request, urllib.error, urllib.parse, zlib
from pathlib import Path

def v1_fixture(path):
    with sqlite3.connect(path) as db:
        db.executescript("\n        CREATE TABLE rooms(id TEXT PRIMARY KEY,owner TEXT NOT NULL,next_seq INTEGER NOT NULL DEFAULT 1);\n        CREATE TABLE members(room TEXT NOT NULL REFERENCES rooms(id),actor TEXT NOT NULL,PRIMARY KEY(room,actor));\n        CREATE TABLE messages(room TEXT NOT NULL REFERENCES rooms(id),seq INTEGER NOT NULL,actor TEXT NOT NULL,client_id TEXT NOT NULL,payload BLOB NOT NULL,created_ms INTEGER NOT NULL,PRIMARY KEY(room,seq),UNIQUE(room,actor,client_id));\n        INSERT INTO rooms VALUES('family','alice',2);INSERT INTO members VALUES('family','alice');INSERT INTO members VALUES('family','bob');\n        INSERT INTO messages VALUES('family',1,'alice','before',X'78',123);\n        PRAGMA application_id=1179471188;PRAGMA user_version=1;\n        ")

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--binary', required=True, type=Path)
    p.add_argument('--old-binary', type=Path)
    a = p.parse_args()
    binary = a.binary.resolve(strict=True)
    old = a.old_binary.resolve(strict=True) if a.old_binary else None
    root = Path(__file__).resolve().parents[1]
    (root / 'artifacts').mkdir(mode=448, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='native-media-', dir=root / 'artifacts'))
    state = work / 'state'
    state.mkdir(mode=448)
    process = output = address = None
    proof = {'synthetic_only': True, 'e2ee': False, 'playback_tested': False, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}

    def start(executable=binary, directory=state):
        nonlocal process, output, address
        log = work / 'server.log'
        output = log.open('ab')
        offset = log.stat().st_size
        process = subprocess.Popen([str(executable), '--synthetic-only', '--state', str(directory), '--listen', '127.0.0.1:0'], stdout=subprocess.DEVNULL, stderr=output)
        until = time.monotonic() + 10
        while time.monotonic() < until:
            if process.poll() is not None:
                raise RuntimeError('prototype exited before listening')
            m = re.search('listening (127\\.0\\.0\\.1:\\d+)', log.read_bytes()[offset:].decode())
            if m:
                address = m[1]
                return
            time.sleep(0.02)
        raise RuntimeError('start timeout')

    def stop(crash=False):
        if process and process.poll() is None:
            process.kill() if crash else process.terminate()
            process.wait(timeout=5)
        if output:
            output.close()

    def req(method, path, data=None, actor='alice', headers=None, want=200):
        hs = {'Authorization': 'Bearer synthetic-' + actor, 'Content-Type': 'application/json'}
        hs.update(headers or {})
        r = urllib.request.Request('http://' + address + path, method=method, headers=hs, data=json.dumps(data).encode() if isinstance(data, dict) else data)
        try:
            response = urllib.request.urlopen(r, timeout=8)
        except urllib.error.HTTPError as e:
            response = e
        with response:
            assert response.status == want, (path, response.status, want)
            return (response.headers, response.read())

    def obj(*args, **kwargs):
        return json.loads(req(*args, **kwargs)[1])

    def upload_headers(key, name, kind, body):
        return {'X-Upload-ID': key, 'X-File-Name': urllib.parse.quote(name, safe=''), 'Content-Type': kind, 'X-Content-SHA256': hashlib.sha256(body).hexdigest()}
    try:
        if old:
            start(old)
            obj('POST', '/v1/rooms', {'id': 'family', 'members': ['bob']}, want=201)
            obj('POST', '/v1/rooms/family/messages', {'client_id': 'before', 'payload': base64.b64encode(b'x').decode()}, want=201)
            stop()
        else:
            v1_fixture(state / 'messages.sqlite')
        start()
        assert obj('GET', '/v1/rooms/family/messages')[0]['client_id'] == 'before'
        snapshots = list((state / 'snapshots').glob('*.sqlite'))
        assert len(snapshots) == 1
        with sqlite3.connect(snapshots[0]) as db:
            assert db.execute('PRAGMA user_version').fetchone()[0] == 1
            assert db.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        proof['v1_migration_and_private_snapshot'] = True

        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\x00\x00\x00\xff')) + chunk(b'IEND', b'')
        samples = [('합성 사진.png', 'image/png', png), ('blue.mp4', 'video/mp4', (root / 'tests/fixtures/native-media/blue.mp4').read_bytes()), ('sample.bin', 'application/octet-stream', bytes(range(256)) * 1024)]
        stored = []
        for i, (name, kind, body) in enumerate(samples):
            hs = upload_headers(str(i), name, kind, body)
            m = obj('POST', '/v1/rooms/family/attachments', body, headers=hs, want=201)
            assert obj('POST', '/v1/rooms/family/attachments', body, headers=hs) == m
            headers, result = req('GET', '/v1/rooms/family/attachments/' + m['id'], actor='bob')
            assert result == body
            assert headers['Content-Type'] == 'application/octet-stream' and headers['X-Content-SHA256'] == hashlib.sha256(result).hexdigest()
            req('GET', '/v1/rooms/family/attachments/' + m['id'], actor='charlie', want=403)
            stored.append(m)
        proof['png_mp4_file_integrity_retry_and_room_acl'] = True
        hs = upload_headers('0', samples[0][0], samples[0][1], png)
        req('POST', '/v1/rooms/family/attachments', b'X' * len(png), headers=hs, want=422)
        req('POST', '/v1/rooms/family/attachments', png, headers=dict(hs, **{'X-File-Name': 'different.png'}), want=409)
        body = b'z' * (1024 * 1024)
        hs = upload_headers('interrupted', 'partial.bin', 'application/octet-stream', body)
        host, port = address.split(':')
        sock = socket.create_connection((host, int(port)), timeout=5)
        fields = {'Host': address, 'Authorization': 'Bearer synthetic-alice', 'Content-Length': str(len(body)), **hs}
        sock.sendall(('POST /v1/rooms/family/attachments HTTP/1.1\r\n' + ''.join((k + ': ' + v + '\r\n' for k, v in fields.items())) + '\r\n').encode() + body[:1024])
        time.sleep(0.1)
        stop(crash=True)
        sock.close()
        start()
        listed = obj('GET', '/v1/rooms/family/attachments')
        assert len(listed) == 3 and all((m['client_id'] != 'interrupted' for m in listed))
        for m, (_, _, data) in zip(stored, samples):
            assert req('GET', '/v1/rooms/family/attachments/' + m['id'])[1] == data
        obj('POST', '/v1/rooms/family/attachments', body, headers=hs, want=201)
        assert len(obj('GET', '/v1/rooms/family/attachments')) == 4
        proof['crash_preserves_ready_and_discards_incomplete_upload'] = True
        req('DELETE', '/v1/rooms/family/members/bob', want=204)
        req('GET', '/v1/rooms/family/attachments/' + stored[0]['id'], actor='bob', want=403)
        stop()
        restore = work / 'restored-v1'
        restore.mkdir(mode=448)
        shutil.copyfile(snapshots[0], restore / 'messages.sqlite')
        start(old or binary, restore)
        assert obj('GET', '/v1/rooms/family/messages')[0]['client_id'] == 'before'
        proof['isolated_snapshot_restore'] = True
        proof['old_executable_rollback_verified'] = bool(old)
        proof['ok'] = True
        stop()
    finally:
        stop()
        (work / 'verification.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(work / 'verification.json')
if __name__ == '__main__':
    os.umask(63)
    main()
