"""Independent PKCS12 ID3 KDF/HMAC oracle and authenticated structure probes."""
import copy,hashlib,hmac,pathlib,subprocess,sys
exe,out=map(pathlib.Path,sys.argv[1:]);fixtures=pathlib.Path('tests/vectors/crypto/encrypted-rsa')
expected='ebeba98ef666cf584dfebad1922952ce1107cccaf63e3d74f357fd195b88dc44';checks=0

def check(path,password='test-only-password',error=None,mode='',iterations=1000000,work=8000000,size=1048576,bags=64,depth=8):
 global checks
 p=subprocess.run([str(exe),str(path),password,mode,str(iterations),str(work),str(size),str(bags),str(depth)],capture_output=True,text=True,timeout=30)
 checks+=1
 assert p.returncode==(1 if error else 0),(path,p.returncode,p.stdout,p.stderr)
 if error:assert (p.stdout.strip()==error if error=='wrong password or corrupt key' else error in p.stdout),(path,error,p.stdout)
 else:assert p.stdout.strip()==expected,(path,p.stdout)

# This independent reference is intentionally ordinary Python, not shared code.
def mac_key(password,salt,count,digest):
 pw=password.encode('utf-16-be')+b'\0\0'
 def repeat(value):return (value*((64*((len(value)+63)//64)+len(value)-1)//len(value)))[:64*((len(value)+63)//64)] if value else b''
 result=hashlib.new(digest,b'\x03'*64+repeat(salt)+repeat(pw)).digest()
 for _ in range(1,count):result=hashlib.new(digest,result).digest()
 return result

class Node:
 def __init__(self,tag,value):self.tag,self.value=tag,value
 def der(self):
  b=b''.join(x.der() for x in self.value) if isinstance(self.value,list) else self.value
  n=len(b);size=bytes([n]) if n<128 else bytes([128+(n.bit_length()+7)//8])+n.to_bytes((n.bit_length()+7)//8,'big')
  return bytes([self.tag])+size+b

def parse(raw,at=0):
 tag=raw[at];size=raw[at+1];pos=at+2
 if size>=128:n=size-128;size=int.from_bytes(raw[pos:pos+n],'big');pos+=n
 end=pos+size
 if tag&32:
  vals=[]
  while pos<end:child,pos=parse(raw,pos);vals.append(child)
  return Node(tag,vals),end
 return Node(tag,raw[pos:end]),end

def load(name):return parse((fixtures/name).read_bytes())[0]
def safe(tree):return parse(tree.value[1].value[1].value[0].value)[0]
def put_safe(tree,value):tree.value[1].value[1].value[0].value=value.der()
def remac(tree,password='test-only-password'):
 mac=tree.value[2];digest=mac.value[0];oid=digest.value[0].value[0].value
 algorithm='sha1' if oid==bytes.fromhex('2b0e03021a') else 'sha256'
 salt=mac.value[1].value;count=int.from_bytes(mac.value[2].value,'big') if len(mac.value)>2 else 1
 digest.value[1].value=hmac.new(mac_key(password,salt,count,algorithm),tree.value[1].value[1].value[0].value,algorithm).digest()
def write(name,tree):path=out/(name+'.p12');path.write_bytes(tree.der());return path

for mode in ['', 'software']:
 for name in ['modern','sha1-mac','keybag']:check(fixtures/(name+'.p12'),mode=mode)
 check(fixtures/'empty.p12','',mode=mode)
 check(fixtures/'utf8.p12','tést-only-password',mode=mode)
 check(fixtures/'long.p12','0'*80,mode=mode)
 check(fixtures/'modern.p12','wrong',error='wrong password or corrupt key',mode=mode)
 check(fixtures/'legacy.p12',error='unsupported legacy PKCS#12 encryption',mode=mode)
 check(fixtures/'no-mac.p12',error='PKCS#12 MacData is required',mode=mode)
check(fixtures/'modern.p12',iterations=1,error='MAC iteration limit exceeded')
check(fixtures/'empty.p12','',iterations=1)
check(fixtures/'modern.p12',work=1,error='key derivation work limit exceeded')
check(fixtures/'modern.p12',work=7000,error='key derivation work limit exceeded')
check(fixtures/'modern.p12',size=10,error='DER byte limit exceeded')
check(fixtures/'keybag.p12',bags=1,error='count limit exceeded')
check(fixtures/'modern.p12','😀',error='unsupported PKCS#12 password encoding')

base=load('modern.p12')
# Verify the independent reference before using it to reauthenticate mutations.
t=copy.deepcopy(base);remac(t);assert t.der()==base.der()
t=load('sha1-mac.p12');same=t.der();remac(t);assert same==t.der()
t=load('empty.p12');same=t.der();remac(t,'');assert same==t.der()
t=load('utf8.p12');same=t.der();remac(t,'tést-only-password');assert same==t.der()

for name,raw,error in [('zero',b'\0','invalid PKCS#12 MAC iteration'),('negative',b'\xff','invalid PKCS#12 MAC iteration'),('huge',(1000001).to_bytes(3,'big'),'MAC iteration limit exceeded')]:
 t=copy.deepcopy(base);t.value[2].value[2].value=raw;check(write(name,t),error=error)
t=copy.deepcopy(base);t.value[2].value[0].value[1].value=bytes([0])*32;check(write('bad-mac',t),error='wrong password or corrupt key')
t=copy.deepcopy(base);t.value[2].value[0].value[0].value[0].value=bytes.fromhex('2a864886f70d01050e');check(write('pbmac1',t),error='unsupported PKCS#12 PBMAC1 MAC')
# Corrupt inner cipher OID, without changing the outer MAC: the MAC failure must
# win over the unsupported algorithm. With a valid MAC the named error wins.
t=copy.deepcopy(base);s=safe(t);encrypted=s.value[0].value[1].value[0];eci=encrypted.value[1];algorithm=eci.value[1]
algorithm.value[0].value=bytes.fromhex('2a864886f70d010c0106');put_safe(t,s)
check(write('mac-before-cipher',t),error='wrong password or corrupt key')
remac(t);check(write('legacy-authenticated',t),error='unsupported legacy PKCS#12 encryption')
# Authenticated ciphertext with deliberately invalid final CBC padding.
t=copy.deepcopy(base);s=safe(t);cipher=s.value[0].value[1].value[0].value[1].value[2]
raw=bytearray(cipher.value);raw[-17]^=1;cipher.value=bytes(raw);put_safe(t,s);remac(t)
check(write('authenticated-bad-padding',t),error='wrong password or corrupt key')
# An authentic MAC with a different encryption password still fails uniformly.
t=copy.deepcopy(base);remac(t,'different-mac-password')
path=write('two-passwords',t);check(path,error='wrong password or corrupt key');check(path,'different-mac-password',error='wrong password or corrupt key')

plain=load('keybag.p12');parts=safe(plain)
key_info=next(ci for ci in parts.value if any(b.value[0].value.endswith(b'\x01') for b in parse(ci.value[1].value[0].value)[0].value))
key_bags=parse(key_info.value[1].value[0].value)[0]
# Valid container/MAC but malformed private-key DER shares the failure point.
t=copy.deepcopy(plain);s=safe(t);ci=copy.deepcopy(key_info);bags=copy.deepcopy(key_bags)
key=bags.value[0].value[1].value[0];key.value=[]
ci.value[1].value[0].value=bags.der();s.value=[ci];put_safe(t,s);remac(t)
check(write('authenticated-bad-key',t),error='wrong password or corrupt key')
# Test exactly-one selection independently of certificates.
t=copy.deepcopy(plain);s=safe(t);s.value=[];put_safe(t,s);remac(t);check(write('no-keys',t),error='contains no private key')
t=copy.deepcopy(plain);s=safe(t);ci=copy.deepcopy(key_info);bags=copy.deepcopy(key_bags);bags.value.append(copy.deepcopy(bags.value[0]));ci.value[1].value[0].value=bags.der();s.value=[ci];put_safe(t,s);remac(t)
check(write('two-keys',t),error='contains multiple private keys')
check(write('two-keys-bounded',t),bags=1,error='bag count limit exceeded')
# Unknown bags / bounded nested SafeContents. Strip attributes for exact depth.
for nesting in [0,1,7,8]:
 t=copy.deepcopy(plain);s=safe(t);ci=copy.deepcopy(key_info);bags=copy.deepcopy(key_bags)
 for bag in bags.value:bag.value=bag.value[:2]
 for _ in range(nesting):bags=Node(48,[Node(48,[Node(6,bytes.fromhex('2a864886f70d010c0a0106')),Node(160,[bags])])])
 ci.value[1].value[0].value=bags.der();s.value=[ci];put_safe(t,s);remac(t)
 check(write('nested-'+str(nesting),t),error='nesting depth limit exceeded' if nesting==8 else None)
t=copy.deepcopy(plain);s=safe(t);ci=copy.deepcopy(key_info);bags=copy.deepcopy(key_bags);bags.value[0].value[0].value=bytes.fromhex('2a864886f70d010c0a0105');ci.value[1].value[0].value=bags.der();s.value=[ci];put_safe(t,s);remac(t)
check(write('secret-bag',t),error='unsupported PKCS#12 bag type')
# Indefinite BER must be refused rather than guessed.
path=out/'indefinite.p12';path.write_bytes(b'\x30\x80'+base.der()[4:]+b'\0\0');check(path,error='invalid PKCS#12 DER container')
print(f'PKCS#12: {checks} interop/MAC/limits/authenticated-corruption checks passed')
