"""Interop and bounded public-parameter corruption probes; only fixture secrets."""
import base64,copy,hashlib,json,pathlib,subprocess,sys
exe,out=map(pathlib.Path,sys.argv[1:]); fixtures=pathlib.Path('tests/vectors/crypto/encrypted-rsa')
key=pathlib.Path('tests/vectors/crypto/rsa-implicit-key.pem')
modulus=subprocess.check_output(['openssl','rsa','-in',str(key),'-modulus','-noout'],text=True).strip().split('=')[1]
expected=hashlib.sha256(bytes.fromhex(modulus)).hexdigest(); checks=0

def check(path,password='test-only-password',error=None,mode='',iterations=None,work=None,size=None):
 global checks
 args=[str(exe),str(path),password,mode]
 if iterations is not None or work is not None or size is not None:args.append(str(1000000 if iterations is None else iterations))
 if work is not None or size is not None:args.append(str(8000000 if work is None else work))
 if size is not None:args.append(str(size))
 p=subprocess.run(args,capture_output=True,text=True,timeout=30)
 checks+=1
 assert p.returncode==(1 if error else 0),(path,p.returncode,p.stdout,p.stderr)
 if error:
  assert (p.stdout.strip()==error if error=='wrong password or corrupt key' else error in p.stdout),(path,error,p.stdout)
 else:assert p.stdout.strip()==expected,(path,p.stdout,expected)

for mode in ['', 'software']:
 for name in ['aes128-sha1','aes128-sha256','aes256-sha1','aes256-sha256','low-count']:
  check(fixtures/(name+'.pem'),mode=mode)
 check(fixtures/'empty-sha1.pem','',mode=mode)
 check(fixtures/'long-password.pem','0'*80,mode=mode)
 check(fixtures/'utf8-password.pem','tést-only-password',mode=mode)
 check(fixtures/'aes256-sha256.pem','wrong',error='wrong password or corrupt key',mode=mode)
 check(fixtures/'legacy-3des.pem',error='unsupported legacy PKCS#12 encryption',mode=mode)
check(key)
check(fixtures/'aes256-sha256.pem',iterations=1,error='iteration limit exceeded')
check(fixtures/'low-count.pem',iterations=1)
check(fixtures/'aes256-sha256.pem',work=1,error='key derivation work limit exceeded')
check(fixtures/'aes256-sha256.pem',size=10,error='DER byte limit exceeded')
check(fixtures/'aes256-sha256.pem',iterations=0,error='invalid RSA key read limits')
check(fixtures/'aes256-sha256.pem','x'*1025,error='password exceeds 1024 bytes')

class Node:
 def __init__(self,tag,value):self.tag,self.value=tag,value
 def der(self):
  b=b''.join(x.der() for x in self.value) if isinstance(self.value,list) else self.value
  n=len(b); length=bytes([n]) if n<128 else bytes([128+(n.bit_length()+7)//8])+n.to_bytes((n.bit_length()+7)//8,'big')
  return bytes([self.tag])+length+b

def parse(raw,at=0):
 tag=raw[at]; size=raw[at+1];pos=at+2
 if size>=128:n=size-128;size=int.from_bytes(raw[pos:pos+n],'big');pos+=n
 end=pos+size
 if tag==48:
  vals=[]
  while pos<end:child,pos=parse(raw,pos);vals.append(child)
  return Node(tag,vals),end
 return Node(tag,raw[pos:end]),end

def load(name):
 raw=base64.b64decode(''.join((fixtures/name).read_text().splitlines()[1:-1]));return parse(raw)[0]
def write(name,tree):
 path=out/(name+'.der');path.write_bytes(tree.der());return path
base=load('aes256-sha256.pem')
# Algorithm / PBES2 parameters / KDF / PBKDF2 parameters
params=lambda t:t.value[0].value[1].value
kdf=lambda t:params(t)[0].value[1].value
mutations=[
 ('zero',lambda t:setattr(kdf(t)[1],'value',b'\0'),'invalid PBKDF2 iteration count'),
 ('negative',lambda t:setattr(kdf(t)[1],'value',b'\xff'),'invalid PBKDF2 iteration count'),
 ('big',lambda t:setattr(kdf(t)[1],'value',(1000001).to_bytes(3,'big')),'iteration limit exceeded'),
 ('overflow',lambda t:setattr(kdf(t)[1],'value',b'\x01'+b'\0'*31),'iteration limit exceeded'),
 ('salt',lambda t:setattr(kdf(t)[0],'value',b'x'*1025),'salt byte limit exceeded'),
 ('salt-source',lambda t:setattr(kdf(t)[0],'tag',6),'unsupported PBKDF2 salt source'),
 ('iv',lambda t:setattr(params(t)[1].value[1],'value',b'x'*15),'invalid AES-CBC IV'),
 ('empty',lambda t:setattr(t.value[1],'value',b''),'invalid AES-CBC ciphertext length'),
 ('partial',lambda t:setattr(t.value[1],'value',b'x'*17),'invalid AES-CBC ciphertext length'),
 ('prf',lambda t:setattr(kdf(t)[2].value[0],'value',bytes.fromhex('2a864886f70d020b')),'unsupported PBKDF2 PRF'),
 ('rc2',lambda t:setattr(params(t)[1].value[0],'value',bytes.fromhex('2a864886f70d0302')),'unsupported RC2 encryption'),
 ('des',lambda t:setattr(params(t)[1].value[0],'value',bytes.fromhex('2b0e030207')),'unsupported DES/3DES encryption'),
 ('pbes1',lambda t:setattr(t.value[0].value[0],'value',bytes.fromhex('2a864886f70d010503')),'unsupported PBES1 encryption'),
 ('keylength',lambda t:kdf(t).insert(2,Node(2,b'\x10')),'keyLength does not match'),
]
for name,mutate,error in mutations:
 t=copy.deepcopy(base);mutate(t);check(write(name,t),error=error)
for name in ['aes128-sha1.pem','aes256-sha1.pem','aes256-sha256.pem']:
 t=load(name)
 kdf(t).insert(2,Node(2,bytes([16 if '128' in name else 32])))
 check(write('length-'+name,t))
# Explicit SHA1 (the OpenSSL default algorithm is normally omitted).
t=load('aes256-sha1.pem');kdf(t).append(Node(48,[Node(6,bytes.fromhex('2a864886f70d0207')),Node(5,b'')]))
check(write('explicit-sha1',t))
t=copy.deepcopy(base);kdf(t)[2].value.pop();check(write('absent-prf-null',t))
t=copy.deepcopy(base);body=bytearray(t.value[1].value);body[-17]^=1;t.value[1].value=bytes(body)
check(write('bad-padding',t),error='wrong password or corrupt key')
# Valid CBC padding but invalid decrypted DER must converge on the same error.
t=copy.deepcopy(base);salt=kdf(t)[0].value;count=int.from_bytes(kdf(t)[1].value,'big');iv=params(t)[1].value[1].value
derived=hashlib.pbkdf2_hmac('sha256',b'test-only-password',salt,count,32)
p=subprocess.run(['openssl','enc','-aes-256-cbc','-K',derived.hex(),'-iv',iv.hex()],input=b'not an RSA DER key',capture_output=True,check=True)
t.value[1].value=p.stdout;check(write('bad-inner-der',t),error='wrong password or corrupt key')
path=out/'trailing.der';path.write_bytes(base.der()+b'\0');check(path,error='invalid EncryptedPrivateKeyInfo')
print(f'encrypted RSA: {checks} interop/limits/corruption checks passed')

# Bound decrypted CRT integer widths before private arithmetic.
raw=subprocess.check_output(['openssl','pkcs8','-topk8','-nocrypt','-in',str(key),'-outform','DER'])
pkcs8=parse(raw)[0];pkcs1=parse(pkcs8.value[2].value)[0]
pkcs1.value[4].value=b'\x01'+b'\0'*2999
pkcs8.value[2].value=pkcs1.der()
p=subprocess.run(['openssl','enc','-aes-256-cbc','-K',derived.hex(),'-iv',iv.hex()],input=pkcs8.der(),capture_output=True,check=True)
t=copy.deepcopy(base);t.value[1].value=p.stdout
check(write('oversized-crt',t),error='wrong password or corrupt key')
print('encrypted RSA: decrypted CRT width cap passed')
