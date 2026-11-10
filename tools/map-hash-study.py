# Slot occupancy and probe lengths of the map's old string hash (FNV-1a) and the word-at-a-time one over key sets of interest.
# Run from the repository root: python3 tools/map-hash-study.py (the model is the runtime's: power-of-two slots, linear probing, growth at half full).
import re, random, sys, glob
M=(1<<64)-1
def s32(x): x&=0xFFFFFFFF; return x-(1<<32) if x>>31 else x
def u64(x): return x & M
def fnv(b):
    h=0xCBF29CE484222325
    for c in b: h=((h^c)*0x100000001B3)&M
    return h
K1=u64(-7046029254386353131); K2=u64(-4658895280553007687)
def new(b):
    n=len(b)
    h=0xCBF29CE484222325
    if n>=4:
        h^=n
        if n>=8:
            i=0
            while i+8<=n:
                h=((h^int.from_bytes(b[i:i+8],'little'))*K1)&M; h^=h>>29; i+=8
            h=((h^int.from_bytes(b[n-8:n],'little'))*K1)&M
        else:
            h=((h^u64(s32(int.from_bytes(b[0:4],'little'))))*K1)&M; h^=h>>29
            h=((h^u64(s32(int.from_bytes(b[n-4:n],'little'))))*K1)&M
        h=((h^(h>>32))*K2)&M; h^=h>>29
        return h
    return fnv(b)
def capacity(n):
    cap=8; used=0
    for u in range(n):
        if (u+1)*2>cap:
            cap=8
            while cap<(u+1)*2+2: cap*=2
    return cap
def study(keys,hf):
    n=len(keys); cap=capacity(n); mask=cap-1
    table=[0]*cap
    maxd=0; tot=0
    for k in keys:
        s=hf(k)&mask; d=0
        while table[s]: s=(s+1)&mask; d+=1
        table[s]=1; tot+=d+1; maxd=max(maxd,d+1)
    # longest occupied run
    run=best=0
    for v in table+table:
        run=run+1 if v else 0; best=max(best,run)
    return n,cap,tot/n,maxd,min(best,cap)
def report(name,keys):
    keys=list(dict.fromkeys(keys))
    a=study(keys,lambda b:fnv(b)); b=study(keys,new)
    print("%-34s n=%-7d cap=%-8d | old: mean %.2f max %-3d run %-4d | new: mean %.2f max %-3d run %-4d"%(name,a[0],a[1],a[2],a[3],a[4],b[2],b[3],b[4]))
# (a) compiler identifiers
idents=[]
for f in sorted(glob.glob('src/**/*.ab',recursive=True))+sorted(glob.glob('stdlib/**/*.ab',recursive=True)):
    idents+=re.findall(rb'[A-Za-z_][A-Za-z0-9_]*',open(f,'rb').read())
report("(a) compiler identifiers",[w for w in idents])
report("(a2) compiler identifiers x first 200k",list(dict.fromkeys(idents))[:200000])
# (b) sequential numeric strings
report("(b) '0'..'999999'",[str(i).encode() for i in range(1000000)])
report("(b2) 'w0'..'w4999' (maps bench)",[b"w%d"%i for i in range(5000)])
report("(b3) 'user-i-name' 200k",[b"user-%d-name"%i for i in range(200000)])
# (c) shared prefix, differing in the last 1-3 bytes; and shared suffix
pre=b"common/long/prefix/of/the/keys/"
alpha=b"abcdefghijklmnopqrstuvwxyz0123456789"
report("(c1) prefix + 1 byte",[pre+bytes([a]) for a in alpha])
report("(c2) prefix + 2 bytes",[pre+bytes([a,b]) for a in alpha for b in alpha])
report("(c3) prefix + 3 bytes",[pre+bytes([a,b,c]) for a in alpha for b in alpha for c in alpha])
suf=b"/shared/long/suffix/of/the/keys"
report("(c4) 1 byte + suffix",[bytes([a])+suf for a in alpha])
report("(c5) 2 bytes + suffix",[bytes([a,b])+suf for a in alpha for b in alpha])
report("(c6) 3 bytes + suffix",[bytes([a,b,c])+suf for a in alpha for b in alpha for c in alpha])
# (d) lengths 1..7
random.seed(1)
for L in range(1,8):
    ks=set()
    target=min(200000,len(alpha)**L//2)
    while len(ks)<target: ks.add(bytes(random.choice(alpha) for _ in range(L)))
    report("(d) random length %d"%L,list(ks))
report("(d8) all of length 1..3 over alpha",[bytes(t) for L in (1,2,3) for t in __import__('itertools').product(alpha,repeat=L)])
