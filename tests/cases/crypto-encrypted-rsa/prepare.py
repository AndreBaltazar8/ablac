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
s+='    0\n}\nfun main(): int = pbePrimitiveChecks()\n@export("check")\nfun primitiveWasmCheck(): int = pbePrimitiveChecks()\n@export("simd_checks")\nfun primitiveArmCheck(): int = pbePrimitiveChecks()\n'
out.write_text(s)
print(i,'independent SHA/PBKDF2 KATs')

base=out.parent.as_posix()
(out.parent/'wasm-build.ab').write_text('import "abla/wasm/build"\nval built = #wasmBuildModule("pbe", "'+out.as_posix()+'", "'+base+'/primitives.wasm", false, false)\nfun main(): int = if (built) 0 else 1\n')
(out.parent/'arm-build.ab').write_text('import "abla/build"\nimport "abla/compiler"\n#compilerGrant("filesystem.write")\ncompile fun objectBuild(): bool {\n val target = defineTarget("pbe-arm", "aarch64-unknown-linux-gnu", "elf", "none", "none", false, false)\n target && buildProgram("pbe-arm", "'+out.as_posix()+'", "'+base+'/primitives-arm.o", "pbe-arm", "object", false, false)\n}\nval built = #objectBuild()\nfun main(): int = if (built) 0 else 1\n')

(out.parent/'abla.toml').write_text('compileCapabilities = ["filesystem.write"]\n')
