import gzip,hashlib,io,json,os,tarfile,sys
from pathlib import Path
p=Path(sys.argv[1]); p.mkdir(parents=True,exist_ok=True)
version='23.1.3-1'; host='x86_64-linux'; root=f'abla-xtensa-llvm-{version}-{host}'
files={'bin/opt':b'opt', 'bin/llc':b'llc', 'lib/libLLVM.test':b'library'}
def sha(x): return hashlib.sha256(x).hexdigest()
def make(name, change=None):
 contents=dict(files)
 if change=='many': contents.update({f'extra/f{i:03d}':b'x' for i in range(150)})
 manifest={'schema':1,'version':'abla-xtensa-llvm-'+version,'platform':host,'llvmVersion':'23.1.3','sourceCommit':'a'*40,'sourceArchiveSha256':'b'*64,'files':{k:sha(v) for k,v in contents.items()}}
 if change=='identity': manifest['platform']='arm64-macos'
 raw=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode()
 data=io.BytesIO()
 with tarfile.open(fileobj=data,mode='w',format=tarfile.USTAR_FORMAT) as t:
  for path,contents in list(contents.items())+[('manifest.json',raw)]+([('extra',b'x')] if change=='extra' else []):
   if change=='filehash' and path=='bin/opt': contents=b'bad'
   prefix='./' if change=='rawpath' else ''
   chosen_root = 'wrong-root' if change=='wrongroot' else root
   entry=tarfile.TarInfo(prefix+chosen_root+'/'+path); entry.mode=0o644 if change=='mode' else (0o755 if path.startswith('bin/') else 0o644); entry.size=len(contents); t.addfile(entry,io.BytesIO(contents))
 tar=data.getvalue()
 if change=='tarbad': tar=bytes([tar[0]^1])+tar[1:]
 archive=gzip.compress(tar,mtime=0)
 if change=='gzipbad': archive=archive[:-1]
 cfg={'version':version,'platform':host,'llvmVersion':'23.1.3','sourceCommit':'a'*40,'sourceArchiveSha256':'b'*64,'archiveSha256':sha(archive),'manifestSha256':sha(raw)}
 if change=='archivehash': cfg['archiveSha256']='0'*64
 if change=='manifesthash': cfg['manifestSha256']='0'*64
 (p/(name+'.tar.gz')).write_bytes(archive); (p/(name+'.json')).write_text(json.dumps(cfg))
for n in ['good','identity','extra','filehash','rawpath','mode','archivehash','manifesthash','many','gzipbad','tarbad','wrongroot']: make(n,None if n=='good' else n)

with (p/'oversize.tar.gz').open('wb') as output: output.truncate(134217729)
