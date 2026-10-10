#!/usr/bin/env python3
"""Separately approved opt-in to the EXISTING owner/library deletion policy API."""
import argparse
import os
from pathlib import Path
import re
from urllib.parse import urlsplit

import release_candidate
import trash_predeploy as pre


def authorize(args):
    # Gate BEFORE touching Docker, the key, or any API. Never enables retention.
    pre.need(args.approve_library and os.environ.get('GALLERY_LIBRARY_DELETION_APPROVED') == 'YES',
             'SEPARATE_OWNER_LIBRARY_APPROVAL_REQUIRED')
    url=urlsplit(args.api)
    pre.need(url.scheme=='http' and url.hostname == '127.0.0.1' and url.port and
             url.path=='/api' and not url.username and not url.password and not url.query and not url.fragment,
             'LOCAL_GALLERY_API_REQUIRED')
    profile = release_candidate.load(args.candidate_profile, args.candidate_profile_sha256)
    pre.private_dir(args.state)
    plan = pre.private_json(args.plan)
    pre.need(set(plan) == {'ownerId','scope','roots','verifiedExclusiveRoots'} and
             re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}', plan['ownerId']) and
             (plan['scope'] == 'managed' or re.fullmatch('[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}',plan['scope'])) and
             plan['verifiedExclusiveRoots'] is True and isinstance(plan['roots'],list) and
             1 <= len(plan['roots']) <= 128 and len(set(plan['roots'])) == len(plan['roots']), 'LIBRARY_PLAN_INVALID')
    nas = pre.private_json(args.state/'nas-verified.json')
    pre.age_ok(nas['verifiedAt'],86400,'NAS_RECOVERY_PROOF_EXPIRED')
    pre.need(nas['validation']=='SAMPLE_BYTE_RECOVERY_PLUS_OPERATOR_SNAPSHOT_SCOPE_ATTESTATION', 'NAS_SCOPE_PROOF_REQUIRED')
    pre.need(all(isinstance(root,str) and Path(root).is_absolute() and root != '/' and
                 any(root == mount or root.startswith(mount.rstrip('/')+'/') for mount in nas['mounts'])
                 for root in plan['roots']), 'ROOT_OUTSIDE_VERIFIED_NAS_SCOPE')
    context = pre.private_json(args.state/'predeploy-context.json')
    proof = next((Path(p) for p in context['evidenceHashes'] if p.endswith('/nas-proof.json')),None)
    pre.need(proof is not None and pre.sha(proof)==context['evidenceHashes'][str(proof)], 'NAS_PROOF_CHANGED')
    pre.need(args.key.is_file() and not args.key.is_symlink() and args.key.stat().st_mode & 0o077 == 0,
             'PRIVATE_EXISTING_ADMIN_KEY_FILE_REQUIRED')
    tool = pre.load_tool(args.pinned_tool,profile)
    pre.journal_image(tool,args.state)
    pre.need(tool.inspect(tool.SERVER)['Image']==tool.IMAGE and tool.api_only(tool.inspect(tool.SERVER)),
             'EXACT_CANDIDATE_API_ONLY_REQUIRED')
    tool.health(args.api,tool.SOURCE)
    tool.queue_empty(require_paused=True)
    # Server rechecks real owner, exact current library roots, filesystem permissions,
    # canonical paths and cross-owner lexical/inode overlap. No shell unlink or NAS API.
    tool.api(args.api,args.key,'/assets/deletion-policy','PUT',
             {**plan,'enabled':True,'recoveryProof':pre.sha(proof)})
    print('PASS one explicitly approved owner/library policy; retention and workers unchanged')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('candidate-profile','state','plan','key'):
        p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--candidate-profile-sha256',required=True)
    p.add_argument('--pinned-tool',type=Path,default=pre.DEFAULT_TOOL)
    p.add_argument('--api',default='http://127.0.0.1:2283/api')
    p.add_argument('--approve-library',action='store_true')
    try: authorize(p.parse_args()); return 0
    except Exception as error:
        code=str(error) if isinstance(error,(pre.Stop,ValueError)) and re.fullmatch('[A-Z0-9_]+',str(error)) else 'LIBRARY_AUTHORIZATION_FAILED'
        print('STOP '+code); return 1


if __name__=='__main__': raise SystemExit(main())
