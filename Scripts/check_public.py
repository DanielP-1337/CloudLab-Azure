#!/usr/bin/env python3
"""Inspect actual Git objects; never echo matched private values."""
import argparse, pathlib, re, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
PATTERNS = [
    ('private material', re.compile(rb'-----BEGIN (?:[A-Z ]*PRIVATE KEY|CERTIFICATE)-----')),
    ('cloud identifier', re.compile(rb'\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b')),
    ('GitHub credential', re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b')),
    ('JWT', re.compile(rb'\beyJ[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b')),
    ('SAS signature', re.compile(rb'[?&]sig=[A-Za-z0-9%+/]{12,}')),
]
DENIED_EXT = {'.pfx','.p12','.pem','.key','.cer','.crt','.der','.bak','.trn','.mdf','.ldf','.dcm','.zip','.gz','.7z','.iso','.log','.dump'}
def git(*args):
    p=subprocess.run(['git','-C',str(ROOT),*args],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if p.returncode: raise RuntimeError('Git command failed; verify repository/index. No private output displayed.')
    return p.stdout

def load_terms(required):
    p=ROOT/'.local/private-terms.txt'
    terms=[]
    if p.exists(): terms=[x.strip().encode().lower() for x in p.read_text().splitlines() if x.strip() and not x.lstrip().startswith('#')]
    if required and not terms: raise RuntimeError('Fill .local/private-terms.txt with private employer/product/domain names before committing/pushing.')
    return terms

def inspect(name,data,allowed,terms):
    issues=[]; path=pathlib.PurePosixPath(name)
    if name not in allowed: issues.append('path is not on public-files.txt allowlist')
    if any(x.lower() in ('.local','.vscode','.git') for x in path.parts) or path.suffix.lower() in DENIED_EXT or '.local.' in name or path.name.startswith('.env'):
        issues.append('local/private path')
    if len(data)>1024*1024 or b'\0' in data: issues.append('binary/oversize file')
    for label,pattern in PATTERNS:
        if pattern.search(data): issues.append(label)
    if any(term in data.lower() or term in name.lower().encode() for term in terms): issues.append('local private-term match')
    return issues

def entries(mode):
    if mode=='worktree':
        for p in ROOT.rglob('*'):
            rel=p.relative_to(ROOT).as_posix()
            if any(x in ('.git','.local','__pycache__') for x in p.relative_to(ROOT).parts): continue
            if p.is_symlink(): yield rel,b'\0symlink'; continue
            if p.is_file(): yield rel,p.read_bytes()
    elif mode=='staged':
        for raw in git('ls-files','--stage','-z').split(b'\0'):
            if not raw: continue
            meta,name=raw.split(b'\t',1); bits=meta.split(); path=name.decode('utf-8')
            if bits[0] not in (b'100644',b'100755') or bits[2]!=b'0': yield path,b'\0unsupported-index-entry'
            else: yield path,git('cat-file','blob',bits[1].decode())
    else:
        # Inspect each path/blob pair in every reachable commit, including old names.
        seen=set()
        for commit in git('rev-list','--all').decode().splitlines():
            for raw in git('ls-tree','-r','-z',commit).split(b'\0'):
                if not raw: continue
                meta,name=raw.split(b'\t',1); mode,kind,oid=meta.split(); path=name.decode('utf-8')
                pair=(path,oid)
                if pair in seen: continue
                seen.add(pair)
                if kind!=b'blob' or mode not in (b'100644',b'100755'): yield path,b'\0unsupported-tree-entry'
                else: yield path,git('cat-file','blob',oid.decode())

def main():
    parser=argparse.ArgumentParser(); group=parser.add_mutually_exclusive_group()
    group.add_argument('--staged',action='store_true'); group.add_argument('--history',action='store_true')
    parser.add_argument('--require-private-terms',action='store_true'); args=parser.parse_args()
    try:
        terms=load_terms(args.require_private_terms)
        allowed=set((ROOT/'public-files.txt').read_text().splitlines())
        mode='staged' if args.staged else 'history' if args.history else 'worktree'
        failures=0; total=0
        for name,data in entries(mode):
            total+=1
            issues=inspect(name,data,allowed,terms)
            if issues:
                failures+=1
                # Even private path names can disclose information: print only ordinal and labels.
                print('BLOCKED object '+str(total)+': '+', '.join(issues),file=sys.stderr)
        if failures: return 1
        print('Public-content checks passed ('+mode+', '+str(total)+' objects). Manual review is still required.')
        return 0
    except Exception as e:
        print('Publication check failed: '+str(e),file=sys.stderr); return 2
if __name__=='__main__': sys.exit(main())
