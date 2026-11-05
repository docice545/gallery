#!/usr/bin/env python3
"""Synthetic HTTP inference against one owned disposable local container.

Standard library only; no user photos, production URLs, model downloads or
registry pulls. Build the existing inpainting Dockerfile first, then pass its
immutable image ID and the existing checksum-pinned model file.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import struct
import subprocess
import time
import urllib.error
import urllib.request
import uuid
import zlib

MODEL_SHA = '344c77bbcb158f17dd143070d1e789f38a66c04202311ae3a258ef66667a9ea9'
DOCKER = ['docker', '--host=unix:///var/run/docker.sock']


def synthetic_png():
    width, height = 480, 320
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend((210, 50, 40) if 210 <= x < 270 and 120 <= y < 235
                        else (130 + x // 12, 140 + y // 16, 135))

    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))

    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', required=True)
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', args.image):
        parser.error('Use an immutable local image ID')
    model = args.model.resolve(strict=True)
    with model.open('rb') as handle:
        if hashlib.file_digest(handle, 'sha256').hexdigest() != MODEL_SHA:
            parser.error('Existing model checksum mismatch')
    if ',' in str(model):
        parser.error('Model path cannot contain a Docker mount separator')
    args.output.mkdir(parents=True, exist_ok=False)
    token = secrets.token_hex(32)
    env = {**os.environ, 'GALLERY_INPAINTING_TOKEN': token}
    for key in ('DOCKER_HOST', 'DOCKER_CONTEXT', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
        env.pop(key, None)
    name = 'foto-inpaint-check-' + uuid.uuid4().hex[:12]
    container = None
    opened = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def docker(*command, input=None):
        return subprocess.check_output(DOCKER + list(command), env=env, input=input, stderr=subprocess.PIPE)

    try:
        docker('image', 'inspect', args.image)
        container = docker('run', '-d', '--pull=never', '--name', name,
            '--label', 'io.foto.acceptance.synthetic=true', '--read-only',
            '--user', '1000:1000', '--cpus', '2', '--memory', '3g', '--pids-limit', '128',
            '--tmpfs', '/tmp:rw,noexec,nosuid,size=1g,mode=1777',
            '--mount', f'type=bind,src={model},dst=/models/big-lama.pt,readonly',
            '-p', '127.0.0.1::3004', '-e', 'GALLERY_INPAINTING_TOKEN',
            '-e', f'INPAINTING_MODEL_SHA256={MODEL_SHA}', args.image).decode().strip()
        bindings = json.loads(docker('inspect', '--format', '{{json .NetworkSettings.Ports}}', container))
        endpoint = 'http://127.0.0.1:' + bindings['3004/tcp'][0]['HostPort']

        def request(path, *, authorization=True, data=None, method=None, content_type=None):
            headers = {'Authorization': 'Bearer ' + token} if authorization else {}
            if content_type:
                headers['Content-Type'] = content_type
            req = urllib.request.Request(endpoint + path, data=data, headers=headers, method=method)
            try:
                with opened.open(req, timeout=180) as response:
                    return response.status, response.read(), dict(response.headers)
            except urllib.error.HTTPError as error:
                return error.code, error.read(), dict(error.headers)

        deadline = time.monotonic() + 45
        while True:
            try:
                status, data, _ = request('/health')
                assert status == 200
                health = json.loads(data)
                assert health['ready'] and health['device'] == 'cpu'
                break
            except (urllib.error.URLError, ConnectionError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(.5)
        assert request('/health', authorization=False)[0] == 401
        image = synthetic_png()
        (args.output / 'synthetic-before.png').write_bytes(image)
        boundary = uuid.uuid4().hex
        mask = json.dumps({'strokes': [{'points': [
            {'x': x / 480, 'y': y / 320}
            for x, y in [(190, 100), (290, 100), (290, 255), (190, 255), (190, 100)]
        ], 'radius': .012, 'erase': False}]})
        body = bytearray()
        for key, value in [('jobId', str(uuid.uuid4())), ('mask', mask)]:
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
        body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="image"; filename="synthetic.png"\r\nContent-Type: image/png\r\n\r\n'.encode())
        body.extend(image)
        body.extend(f'\r\n--{boundary}--\r\n'.encode())
        started = time.monotonic()
        status, result, headers = request('/inpaint', data=body, content_type='multipart/form-data; boundary=' + boundary)
        seconds = time.monotonic() - started
        assert status == 200, (status, result[:200])
        assert headers.get('cache-control') == 'no-store'
        assert result.startswith(b'\xff\xd8')
        (args.output / 'synthetic-after.jpg').write_bytes(result)
        geometry = docker('exec', '-i', container, 'python', '-c',
            'import io,sys,json; from PIL import Image; im=Image.open(io.BytesIO(sys.stdin.buffer.read())); print(json.dumps(list(im.size)))', input=result)
        assert json.loads(geometry) == [480, 320]
        assert hashlib.sha256((args.output / 'synthetic-before.png').read_bytes()).digest() == hashlib.sha256(image).digest()
        assert json.loads(request('/jobs/' + str(uuid.uuid4()), method='DELETE')[1]) == {'cancelled': False}
        leftovers = docker('exec', container, 'python', '-c',
            'import json; from pathlib import Path; print(json.dumps([p.name for p in Path("/tmp/gallery-inpainting").iterdir()]))')
        assert json.loads(leftovers) == []
        receipt = {'status': 'PASS', 'syntheticOnly': True, 'imageId': args.image, 'modelSHA256': MODEL_SHA,
            'cpuLimit': 2, 'memoryLimitGiB': 3, 'httpInferenceSeconds': round(seconds, 3),
            'checks': ['auth401', 'modelReady', 'realHttpInference200', 'jpeg480x320',
                       'originalPreserved', 'noStore', 'unknownCancellationIdempotent', 'temporaryFilesCleaned'],
            'beforeSHA256': hashlib.sha256(image).hexdigest(), 'afterSHA256': hashlib.sha256(result).hexdigest(),
            'deviceAcceptance': 'DEVICE_REQUIRED', 'productionChanged': False}
        (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps(receipt, indent=2))
    finally:
        if container:
            try:
                logs = subprocess.run(DOCKER + ['logs', container], env=env,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
                (args.output / 'container-private.log').write_bytes(logs.stdout)
            finally:
                docker('rm', '-f', container)


if __name__ == '__main__':
    main()
