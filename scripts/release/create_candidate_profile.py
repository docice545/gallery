#!/usr/bin/env python3
"""Seal artifacts downloaded by the existing proof workflow; no build/sign/deploy."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess

import android_release as android
from release_candidate import BASE, digest, need, validate


def build(root, source, runs, output):
    need(not output.exists(), 'NEW_PROFILE_OUTPUT_REQUIRED')
    backend = json.loads((root/'backend/manifest.json').read_text())
    provenance = {}
    # gh handles this workflow's read-only token. Never emits it or credentials.
    for platform, run in zip(('backend', 'android', 'ios'), runs, strict=True):
        data = json.loads(subprocess.check_output(['gh', 'api', f'repos/docice545/gallery/actions/runs/{run}'], text=True))
        need(data['status'] == 'completed' and data['conclusion'] == 'success', 'SUCCESSFUL_BUILD_REQUIRED')
        if platform == 'backend':
            # A harness-only fix can have a distinct workflow HEAD. The image is
            # built from git archive(source), with all app inputs checked identical.
            need(data['head_sha'] == backend['toolingCommit'] and backend['sourceCommit'] == source,
                 'BACKEND_SOURCE_OR_TOOLING_PROVENANCE')
            subprocess.run(['git','merge-base','--is-ancestor',source,data['head_sha']],check=True)
            subprocess.run(['git','diff','--exit-code',source,data['head_sha'],'--','server','mobile','web',
                            'packages','i18n','branding','package.json','pnpm-lock.yaml','pnpm-workspace.yaml',
                            '.pnpmfile.cjs','patches','.dockerignore'],check=True,capture_output=True)
        else:
            need(data['head_sha'] == source, 'SUCCESSFUL_SAME_SOURCE_RUNS_REQUIRED')
        expected = 'gallery-trash-server-build.yml' if platform == 'backend' else 'gallery-build-mobile.yml'
        need(data['path'].endswith('/' + expected), 'UNEXPECTED_BUILD_WORKFLOW')
        items = json.loads(subprocess.check_output(['gh', 'api', f'repos/docice545/gallery/actions/runs/{run}/artifacts'], text=True))['artifacts']
        name = {'backend':'gallery-trash-server-linux-amd64', 'android':'android-media-pilot-validation-apk', 'ios':'ios-unsigned-ipa'}[platform]
        matches = [item for item in items if item['name'] == name and not item['expired']]
        need(len(matches) == 1, 'EXPECTED_BUILD_ARTIFACT_MISSING_OR_AMBIGUOUS')
        provenance[platform] = matches[0]['id']
    need(digest(root/'backend/gallery-server-linux-amd64.tar.gz') == backend['archiveSHA256'], 'BACKEND_ARCHIVE_CHANGED')
    apk = root/'android/app-release.apk'
    sdk = android.sdk_path(os.environ)
    signature = android.run([str(sdk/'build-tools/36.0.0/apksigner'),'verify','--print-certs',str(apk)], Path.cwd())
    import re
    certificates = re.findall(r'^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)\s*$', signature, re.MULTILINE)
    need(len(certificates) == 1, 'SINGLE_CI_CERTIFICATE_REQUIRED')
    certificate = certificates[0].lower().replace(':','')
    # The fresh runner generates its own debug key. Provenance is the exact
    # successful source/run/artifact, then this certificate is frozen in the profile.
    need(certificate != android.CERTIFICATE_SHA256, 'HP_PRODUCTION_SIGNER_FORBIDDEN_IN_CI')
    android.apk_metadata(apk,sdk,Path.cwd(),'5.7.2',9,certificate)
    profile = dict(schemaVersion=2, productionBase=BASE, sourceCommit=source, serverVersion='5.7.2',
                   mobileVersion='5.7.2', mobileBuild=9, backend=backend, backendRun=runs[0],
                   backendArtifactId=provenance['backend'],
                   android=dict(sourceCommit=source,run=runs[1],artifactId=provenance['android'],sha256=digest(apk),certificateSHA256=certificate),
                   ios=dict(sourceCommit=source,run=runs[2],artifactId=provenance['ios'],sha256=digest(root/'ios/Photos-unsigned.ipa')))
    validate(profile)
    with output.open('x') as file: file.write(json.dumps(profile,indent=2)+'\n')
    print('PASS identical successful application revisions and immutable artifact hashes')
    print('CANDIDATE_PROFILE_SHA256='+digest(output))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifacts',type=Path); parser.add_argument('source')
    parser.add_argument('backend_run',type=int); parser.add_argument('android_run',type=int); parser.add_argument('ios_run',type=int)
    parser.add_argument('new_profile',type=Path)
    args = parser.parse_args()
    build(args.artifacts,args.source,[args.backend_run,args.android_run,args.ios_run],args.new_profile)
