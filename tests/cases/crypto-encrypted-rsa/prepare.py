from pathlib import Path
import hashlib,json,sys
out=Path(sys.argv[1]) / 'primitives.ab'
out.parent.mkdir(parents=True,exist_ok=True)
s=Path('stdlib/abla/crypto/pbe/entry.ab').read_text()+'\n'+Path('tests/cases/crypto-encrypted-rsa/primitive-test.inc').read_text()+'\n'
s+='fun pbePrimitiveChecks(): int {\n'
i=0
for message in [b'',b'abc',b'a'*55,b'a'*56,b'a'*64,b'a'*127,b'a'*128,bytes(range(256))]:
 for digest in ['sha1','sha256']:
  i+=1;txt='"'+''.join('\\x%02x'%v for v in message)+'"'
  s+=f'    if (hexEncode(pbeTestHash({txt}, {str(digest=="sha1").lower()})) != "{hashlib.new(digest,message).hexdigest()}") return {i}\n'
for password,salt,count in [(b'password',b'salt',1),(b'password',b'salt',2),(b'password',b'salt',4096),(b'pass\0word',b'sa\0lt',3),(b'x'*80,b'z'*80,17),(b'',b'',1)]:
 for digest in ['sha1','sha256']:
  for length in [16,32]:
   i+=1;p='"'+''.join('\\x%02x'%v for v in password)+'"';t='"'+''.join('\\x%02x'%v for v in salt)+'"'
   expected=hashlib.pbkdf2_hmac(digest,password,salt,count,length).hex()
   s+=f'    if (hexEncode(pbeTestDerive({p}, {t}, {count}, {str(digest=="sha1").lower()}, {length})) != "{expected}") return {i}\n'

def pfx_key(password,salt,count,digest):
 pw=password.encode('utf-16-be')+b'\0\0'
 def repeat(value):return (value*((64*((len(value)+63)//64)+len(value)-1)//len(value)))[:64*((len(value)+63)//64)] if value else b''
 result=hashlib.new(digest,b'\x03'*64+repeat(salt)+repeat(pw)).digest()
 for _ in range(1,count):result=hashlib.new(digest,result).digest()
 return result
for password,salt,count in [('password',b'salt',1),('',b'',1),('tést',bytes(range(80)),17),('x'*80,b'salt',17),('test-only-password',b'public-salt',2048)]:
 for digest in ['sha1','sha256']:
  i+=1;p=json.dumps(password);t='"'+''.join('\\x%02x'%v for v in salt)+'"'
  expected=pfx_key(password,salt,count,digest).hex()
  s+=f'    if (hexEncode(pbeTestMacKey({p}, {t}, {count}, {str(digest=="sha1").lower()})) != "{expected}") return {i}\n'
s+='    val nulPassword = cryptoPassword("a\\x00b")\n    if (pbeOpenPkcs12("", nulPassword).error != "PKCS#12 password contains NUL") return 90\n'
s+='    val astralPassword = cryptoPassword("\\xf0\\x9f\\x98\\x80")\n    if (pbeOpenPkcs12("", astralPassword).error != "unsupported PKCS#12 password encoding (UTF-8 BMP text required)") return 91\n'
s+='    0\n}\nfun main(): int = pbePrimitiveChecks()\n@export("check")\nfun primitiveWasmCheck(): int = pbePrimitiveChecks()\n@export("simd_checks")\nfun primitiveArmCheck(): int = pbePrimitiveChecks()\n'
out.write_text(s)
print(i,'independent SHA/PBKDF2/PKCS12 KATs')

base=out.parent.as_posix()
(out.parent/'wasm-build.ab').write_text('import "abla/wasm/build"\nval built = #wasmBuildModule("pbe", "'+out.as_posix()+'", "'+base+'/primitives.wasm", false, false)\nfun main(): int = if (built) 0 else 1\n')
(out.parent/'arm-build.ab').write_text('import "abla/build"\nimport "abla/compiler"\n#compilerGrant("filesystem.write")\ncompile fun objectBuild(): bool {\n val target = defineTarget("pbe-arm", "aarch64-unknown-linux-gnu", "elf", "none", "none", false, false)\n target && buildProgram("pbe-arm", "'+out.as_posix()+'", "'+base+'/primitives-arm.o", "pbe-arm", "object", false, false)\n}\nval built = #objectBuild()\nfun main(): int = if (built) 0 else 1\n')

(out.parent/'abla.toml').write_text('compileCapabilities = ["filesystem.write"]\n')

reader=out.parent/'reader.ab'
fixture=Path('tests/vectors/crypto/encrypted-rsa/empty.p12').read_bytes()
hextext=fixture.hex()
reader.write_text('import "abla/crypto/rsa"\nimport "abla/crypto"\nimport "abla/bytes"\nvar readerState = 1\nfun readerRandom(count: int): string {\n val out = byteBuffer()\n for(i in 0 until count) { readerState = (readerState * 1103515245 + 12345) & 2147483647; out.appendText(byteEncode((readerState >> 16) & 255)) }\n out.toText()\n}\nfun readerCheck(): int {\n cryptoSetRandom({ count: int -> readerRandom(count) })\n val password = cryptoPassword("")\n val key = rsaPrivateKeyFromPkcs12(hexDecode("'+hextext+'"), password)\n if (!key.ok() || key.bits != 2048) return 1\n if (hexEncode(sha256(key.modulus)) != "ebeba98ef666cf584dfebad1922952ce1107cccaf63e3d74f357fd195b88dc44") return 2\n 0\n}\nfun main(): int = readerCheck()\n@export("check")\nfun check(): int = readerCheck()\n@export("simd_checks")\nfun armCheck(): int = readerCheck()\n')
(out.parent/'reader-wasm-build.ab').write_text((out.parent/'wasm-build.ab').read_text().replace('primitives.ab','reader.ab').replace('primitives.wasm','reader.wasm'))
(out.parent/'reader-arm-build.ab').write_text((out.parent/'arm-build.ab').read_text().replace('primitives.ab','reader.ab').replace('primitives-arm.o','reader-arm.o'))
