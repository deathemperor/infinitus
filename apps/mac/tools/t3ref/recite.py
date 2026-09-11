#!/usr/bin/env python3
"""Rewrite upstream `File.tsx:NN[-MM]` citations in Swift files from OLD sha's
line numbers to NEW sha's (difflib over `git show`; only files that changed
between the two shas move; an unmapped line carries the nearest offset).

    tools/t3ref/recite.py [--dry] OLD NEW file.swift...

`--dry` prints what would move and writes nothing. T3REF_UPSTREAM overrides
the checkout (default ~/death/t3code). Citations must be against one sha per
file: run it only over files whose citations are all at OLD."""
import subprocess, difflib, re, sys, os
args=sys.argv[1:]
dry="--dry" in args; args=[a for a in args if a!="--dry"]
if len(args)<3: sys.exit(__doc__)
T3=os.environ.get("T3REF_UPSTREAM", os.path.expanduser("~/death/t3code")); OLD, NEW=args[0], args[1]; args=args[2:]
changed=set(subprocess.run(["git","-C",T3,"diff","--name-only",OLD,NEW],capture_output=True,text=True).stdout.split())
byname={}
for p in subprocess.run(["git","-C",T3,"ls-tree","-r","--name-only",NEW],capture_output=True,text=True).stdout.split():
    byname.setdefault(os.path.basename(p),[]).append(p)
def show(sha,path): return subprocess.run(["git","-C",T3,"show",f"{sha}:{path}"],capture_output=True,text=True).stdout.splitlines()
maps={}
def mapper(path):
    if path not in maps:
        a=show(OLD,path); b=show(NEW,path); m={}
        for tag,i1,i2,j1,j2 in difflib.SequenceMatcher(None,a,b,autojunk=False).get_opcodes():
            if tag=="equal":
                for k in range(i2-i1): m[i1+k+1]=j1+k+1
        def f(n):
            if n in m: return m[n]
            lo=max((k for k in m if k<n),default=None)
            return m[lo]+(n-lo) if lo else n
        maps[path]=f
    return maps[path]
pat=re.compile(r'`?([A-Za-z0-9_./-]+\.(?:tsx?|css))(:)(\d+)(?:-(\d+))?')
report=[]
for swift in args:
    s=open(swift).read()
    def sub(mo):
        name=mo.group(1); base=os.path.basename(name)
        cands=[p for p in byname.get(base,[]) if p.endswith(name.lstrip("./")) or name==base]
        cands=[p for p in cands if p in changed]
        if len(cands)!=1: return mo.group(0)
        f=mapper(cands[0]); a=int(mo.group(3)); b=mo.group(4)
        na=f(a); nb=f(int(b)) if b else None
        if na==a and (nb is None or nb==int(b)): return mo.group(0)
        report.append(f"{os.path.basename(swift)}: {name}:{a}{'-'+b if b else ''} -> {na}{'-'+str(nb) if nb else ''}")
        return mo.group(0)[:mo.start(3)-mo.start(0)]+str(na)+(f"-{nb}" if nb else "")
    s2=pat.sub(sub,s)
    if s2!=s and not dry: open(swift,"w").write(s2)
print("\n".join(report) or "no changes")
