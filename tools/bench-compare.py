#!/usr/bin/env python3
"""Compares two compilers on tests/benchmarks: what they cost to compile, how big the
stripped result is, and how fast it runs, as B's change against A.

    tools/bench-compare.py A:compiler.bin:sysroot B:compiler.bin:sysroot [--self] [--fast]
        [--progs a,b] [--rounds N] [--builds N] [--extra name:source.ab] [--pin CPUS]

Run in the shell with `perf` on PATH (nix-build '<nixpkgs>' -A linuxPackages.perf). Builds
and runs take turns, and each metric keeps its best round (and the run metrics their median). Instructions are the numbers to
trust on a loaded machine: they repeat exactly. Cycles and times move with whatever shares
the core. On a hybrid CPU give --pin the P-cores' first threads, or counters split between
core types (the default is this project's i9-13900K, whose CPUs 12 and 13 are offline)."""
import statistics,json,os,subprocess,sys,tempfile,resource,math,argparse,time
P='perf'
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ap=argparse.ArgumentParser();ap.add_argument('a');ap.add_argument('b');ap.add_argument('--progs',default='');ap.add_argument('--rounds',type=int,default=7);ap.add_argument('--builds',type=int,default=2);ap.add_argument('--self',action='store_true');ap.add_argument('--fast',action='store_true');ap.add_argument('--pin',default='0,2,4,6,8,10,14');ap.add_argument('--extra',action='append',default=[]);a=ap.parse_args()
PIN=a.pin
B=ROOT+'/tests/benchmarks/'
SRC={n:B+'perf/'+n+'.ab' for n in 'fib sieve nbody trees strings maps dispatch matrix'.split()}
SRC.update({'websocket-codec':B+'websocket-codec.ab','json-readers':B+'json-readers.ab','json-megabyte':B+'json-megabyte.ab','event-http-server':ROOT+'/examples/event-http-server.ab','https-client':ROOT+'/examples/https-client.ab'})
SRC.update(x.split(':',1) for x in a.extra)
RUN={n:[] for n in 'fib sieve nbody trees strings maps dispatch matrix websocket-codec'.split()};RUN.update({'json-readers':['3000','100'],'json-megabyte':['30000']})
ALL=list(SRC)
if a.self: ALL.append('self')
if a.progs: ALL=a.progs.split(',')
V=[dict(zip(('l','c','s'),x.split(':'))) for x in(a.a,a.b)]
def lim():
    hard=resource.getrlimit(resource.RLIMIT_STACK)[1]
    want=131072*1024
    resource.setrlimit(resource.RLIMIT_STACK,(want if hard==resource.RLIM_INFINITY else min(want,hard),hard))
def st(cmd,env=None,cwd=None):
    fd,f=tempfile.mkstemp();os.close(fd);t=time.time()
    r=subprocess.run(['taskset','-c',PIN,P,'stat','-x,','-o',f,'-e','cpu_core/instructions/u,cpu_core/cycles/u,task-clock']+cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env,cwd=cwd,preexec_fn=lim)
    d=dict(i=0.0,c=0.0,t=0.0,rc=r.returncode,out=r.stdout.decode(errors='replace')[-1500:],w=time.time()-t)
    for l in open(f):
        p=l.split(',')
        if len(p)>2 and p[0].replace('.','',1).isdigit():
            if 'instr' in p[2]:d['i']+=float(p[0])
            elif 'cycles' in p[2]:d['c']+=float(p[0])
            elif 'task-clock' in p[2]:d['t']+=float(p[0])/1e9
    os.unlink(f);return d
W=tempfile.mkdtemp();R={}
for n in ALL:
    for v in V:
        src=SRC[n] if n!='self' else 'src/orc_main.ab'
        cwd=os.path.dirname(SRC[n]) if n!='self' else v['s']
        env=dict(os.environ,ABLA_SYSROOT=v['s'],ABLA_MAX_MEMORY_MB='6000')
        o=f"{W}/{v['l']}-{n}";best=None;fi=None
        for _ in range(a.builds if n!='self' else 1):
            d=st([v['c'],'build',src,'-o',o,'--no-cache'],env,cwd)
            if d['rc']: print('BUILD FAIL',v['l'],n,d['out'],file=sys.stderr);break
            if not best or d['i']<best['i']:best=d
        if not best: continue
        if a.fast and n!='self':
            d=st([v['c'],'build',src,'-o',o+'.fast','--no-cache','--fast'],env,cwd);fi=d['i'] if not d['rc'] else None
        subprocess.run(['strip','-o',o+'.s',o],check=True)
        R[v['l'],n]=dict(ci=best['i'],cc=best['c'],ct=best['t'],sz=os.path.getsize(o+'.s'),fi=fi,ri=1e30,rc=1e30,rt=1e30)
for n in ALL:
    if n not in RUN or not all((v['l'],n) in R for v in V): continue
    for _ in range(a.rounds):
        for v in V:
            d=st([f"{W}/{v['l']}-{n}"]+RUN[n])
            if d['rc']: print('RUN FAIL',v['l'],n,d['out'][-300:],file=sys.stderr);continue
            r=R[v['l'],n];r['ri']=min(r['ri'],d['i']);r['rc']=min(r['rc'],d['c']);r['rt']=min(r['rt'],d['t']);r.setdefault('cs',[]).append(d['c']);r.setdefault('ts',[]).append(d['t'])
for r in R.values():
    if r.get('cs'):
        r['rm']=statistics.median(r['cs']);r['tm']=statistics.median(r['ts'])
A,Bv=V[0]['l'],V[1]['l']
names=[n for n in ALL if (A,n) in R and (Bv,n) in R]
print(f"{'':12}"+''.join(f'{n[:8]:>9}' for n in names)+'      GEO')
for k,l in(('ci','comp-ins'),('cc','comp-cyc'),('fi','fast-ins'),('sz','size'),('ri','run-ins'),('rc','run-cyc'),('rt','run-time'),('rm','run-cyc-med'),('tm','run-time-med')):
    row=[];v=[]
    for n in names:
        x,y=R[A,n].get(k),R[Bv,n].get(k)
        if x and y and x<1e29 and y<1e29:row.append(f'{(y/x-1)*100:+8.1f}%');v.append(y/x)
        else:row.append(' '*9)
    if v:print(f'{l:12}'+''.join(row)+f'{(math.exp(sum(map(math.log,v))/len(v))-1)*100:+8.1f}%')
print('A compG',[round(R[A,n]['ci']/1e9,1) for n in names]);print('A size',[R[A,n]['sz'] for n in names])
subprocess.run(['rm','-rf',W])
