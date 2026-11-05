"""Welch first-order tests, uncropped and dudect's class-blind pilot crops.
Not a constant-time proof or a calibrated multi-test p-value.
"""
import math, struct

class Moments:
    def __init__(self): self.n=0; self.mean=0.; self.m2=0.
    def push(self,x):
        self.n+=1; delta=x-self.mean; self.mean+=delta/self.n; self.m2+=delta*(x-self.mean)
    def record(self): return {'n':self.n,'mean':self.mean,'variance':self.m2/(self.n-1) if self.n>1 else None}

def welch(a,b):
    if min(a.n,b.n)<2:return None
    denominator=math.sqrt(max(0.,a.m2/(a.n-1)/a.n+b.m2/(b.n-1)/b.n))
    return (a.mean-b.mean)/denominator if denominator else (0. if a.mean==b.mean else math.copysign(math.inf,a.mean-b.mean))

def read_samples(path):
    raw=path.read_bytes()
    if len(raw)<16 or raw[:8]!=b'ABLATSC1':raise ValueError('missing sampler header')
    n,=struct.unpack_from('<Q',raw,8)
    if len(raw)!=16+16*n:raise ValueError('truncated sampler records')
    rows=list(struct.iter_unpack('<QQ',raw[16:]))
    if any(c not in (0,1,2) for _,c in rows):raise ValueError('invalid class')
    return rows

def analyze(rows, *, warmup=128, pilot=4096, minimum=10000, threshold=10.):
    if len(rows)<warmup+pilot+4:raise ValueError('not enough records for independent pilot')
    pilot_rows=[x for x,c in rows[warmup:warmup+pilot] if c<2 and 0<x<(1<<63)]
    if len(pilot_rows)<2:raise ValueError('pilot has no valid timings')
    pilot_rows.sort()
    # Same exponential percentiles as dudect, fitted only to the pilot, pooled
    # across classes. Keep the uncut test regardless of any crop.
    cuts=sorted(set(pilot_rows[min(len(pilot_rows)-1,int(len(pilot_rows)*(1-0.5**(10*(i+1)/100))))] for i in range(100)))
    measured=rows[warmup+pilot:]
    valid=sorted((x,c) for x,c in measured if c<2 and 0<x<(1<<63))
    contexts=[]; moments=[Moments(),Moments()]; cursor=0
    def capture(cut):
        t=welch(*moments); eligible=min(v.n for v in moments)>=minimum
        contexts.append({'cut_below_ticks':cut,'class0':moments[0].record(),'class1':moments[1].record(),'eligible':eligible,'t':t})
    for cut in cuts:
        while cursor<len(valid) and valid[cursor][0]<cut:
            x,c=valid[cursor];moments[c].push(x);cursor+=1
        capture(cut)
    while cursor<len(valid):
        x,c=valid[cursor];moments[c].push(x);cursor+=1
    capture(None)
    eligible=[c for c in contexts if c['eligible'] and c['t'] is not None]
    strongest=max(eligible,key=lambda c:abs(c['t'])) if eligible else None
    max_t=abs(strongest['t']) if strongest else None
    status='insufficient samples' if max_t is None else ('leak detected' if max_t>threshold else 'no leak detected')
    return {'status':status,'samples_requested':len(measured),'samples_valid':len(valid),'samples_rejected':len(measured)-len(valid),'warmup':warmup,'pilot':pilot,'minimum_per_class':minimum,'threshold':threshold,'max_abs_t':max_t,'strongest_crop':strongest['cut_below_ticks'] if strongest else None,'raw_t':contexts[-1]['t'],'tests':contexts}

def finite_json(value):
    if isinstance(value,float) and not math.isfinite(value):return 'inf' if value>0 else '-inf'
    if isinstance(value,dict):return {k:finite_json(v) for k,v in value.items()}
    if isinstance(value,list):return [finite_json(v) for v in value]
    return value
