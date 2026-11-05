"""Protocol-only fixtures. Run against a built compiler; never executes source CT."""
import json, os, pathlib, subprocess, sys, shutil
# Absolute, not resolved: build/ablac is a symlink to a launcher that finds
# its payload beside the name it was run as.
compiler=pathlib.Path(os.path.abspath(sys.argv[1]))
root=pathlib.Path('build/analysis-graph').resolve()
root.mkdir(parents=True,exist_ok=True)

class Session:
 def __init__(self, project, *, graph=True):
  self.id=0
  self.stderr=(project/'service.stderr').open('w')
  self.p=subprocess.Popen([str(compiler),'analyze','--stdio'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.stderr)
  self.project=project
  params={'workspaceRoots':[str(project)],'clientName':'graph-fixture','clientVersion':'1'}
  if graph:params['analysisMode']='graph-v1'
  init=self.rpc('initialize',params)['result']; assert init['protocolVersion']==1
  assert ('module-graph-analysis-v1' in init['capabilities'])==graph
 def rpc(self,method,params):
  self.id+=1
  self.p.stdin.write((json.dumps({'schema':1,'id':self.id,'method':method,'params':params})+'\n').encode());self.p.stdin.flush()
  line=self.p.stdout.readline()
  assert line,(method,self.p.poll(),(self.project/'service.stderr').read_text())
  result=json.loads(line);assert result['schema']==1 and result['id']==self.id
  return result
 def analyze(self):
  result=self.rpc('analyze',{})['result']
  assert isinstance(result['revision'],str)
  for d in result['documents']:
   assert set(['uri','version','text','symbols','occurrences','diagnostics'])<=set(d)
   for symbol in d['symbols']:
    assert set(['id','name','kind','uri','range','selectionRange','detail','topLevel'])<=set(symbol)
  return result
 def close(self):
  self.rpc('shutdown',{});self.p.stdin.close();assert self.p.wait(timeout=10)==0;self.stderr.close()

def fixture(name, files, manifest='name = "analysis-fixture"\nentry = "main.ab"\n'):
 p=root/name;p.mkdir(exist_ok=True)
 (p/'abla.toml').write_text(manifest)
 for name,text in files.items():
  target=p/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_text(text)
 return p

def doc(snapshot,path):
 return next(d for d in snapshot['documents'] if d['uri']==path.as_uri())
def errors(snapshot):return [(d['uri'],v['code'],v['message']) for d in snapshot['documents'] for v in d['diagnostics']]
def occurrence(d,name):return [o for o in d['occurrences'] if o['name']==name]

def simple():
 p=fixture('simple',{'main.ab':'// café 😀\nimport "dep.ab"\nfun main: int = answer()\n','dep.ab':'fun answer: int = 42\n'})
 s=Session(p);a=s.analyze();assert not errors(a),errors(a)
 main,dep=doc(a,p/'main.ab'),doc(a,p/'dep.ab')
 target=next(x for x in dep['symbols'] if x['name']=='answer')
 assert occurrence(main,'answer')[0].get('declarationId')==target['id'],occurrence(main,'answer')
 assert occurrence(main,'answer')[0].get('type')
 before=(p/'dep.ab').read_bytes()
 r=s.rpc('document/open',{'uri':(p/'dep.ab').as_uri(),'version':1,'text':'fun answer: string = "x"\n'});assert 'error' not in r
 b=s.analyze();assert errors(b),'cross-file inferred type change was not diagnosed'
 assert doc(b,p/'dep.ab')['version']==1
 stale=s.rpc('document/change',{'uri':(p/'dep.ab').as_uri(),'version':0,'text':''});assert stale['error']['code']=='stale_document'
 s.rpc('document/close',{'uri':(p/'dep.ab').as_uri()});c=s.analyze();assert not errors(c),errors(c)
 assert (p/'dep.ab').read_bytes()==before
 s.close()

def alias_private():
 p=fixture('private',{'main.ab':'import "a.ab" as a\nimport "b.ab" as b\nfun main: int = a.run() + b.run()\n',
  'a.ab':'private fun hidden: int = 1\nfun run: int = hidden()\n',
  'b.ab':'private fun hidden: int = 2\nfun run: int = hidden()\n'})
 s=Session(p);a=s.analyze();assert not errors(a),errors(a)
 for module in ['a.ab','b.ab']:
  d=doc(a,p/module);sy=next(x for x in d['symbols'] if x['name']=='hidden')
  refs=occurrence(d,'hidden');assert len(refs)==2 and all(x.get('declarationId')==sy['id'] for x in refs),(module,refs,sy)
 s.close()

def generic_fields():
 p=fixture('generic-fields',{'main.ab':'class Box<T>(val item: T) { fun get(): T = item }\nfun <T> identity(value: T): T = value\nfun main: int {\n    val box = Box<int>(identity(42))\n    box.get()\n}\n'})
 s=Session(p);a=s.analyze();assert not errors(a),errors(a)
 d=doc(a,p/'main.ab')
 for name in ['identity','get','item']:
  refs=occurrence(d,name);assert len(refs)>=2,(name,refs)
  assert refs[-1].get('declarationId'),(name,refs)
 s.close()

def no_eval():
 sentinel=root/'forbidden';sentinel.unlink(missing_ok=True)
 p=fixture('no-eval',{'main.ab':f'import "abla/compiler"\n#compilerGrant("filesystem.write")\nval wrote = #compilerWriteFile({json.dumps(str(sentinel))}, "bad")\nfun main: int = 0\n'},
  'name = "no-eval"\nentry = "main.ab"\ncompileCapabilities = ["filesystem.write"]\n')
 s=Session(p);a=s.analyze();assert not sentinel.exists();assert a['pending'] and not a['complete']
 assert not errors(a),errors(a)
 v=s.rpc('refactor/validate',{'baseRevision':a['revision'],'edits':[],'invariants':['no-new-errors']})['result']
 assert v['valid'] is False and 'incomplete' in v['reason']
 s.close()

def strict():
 p=fixture('strict',{'main.ab':'import "a.ab"\nfun main: int = secret()\n','a.ab':'import "b.ab"\nfun exposed: int = 1\n','b.ab':'fun secret: int = 42\n'},
  'name = "strict"\nentry = "main.ab"\nvisibility = "imports"\n')
 s=Session(p);a=s.analyze();assert any('IMPORT' in e[1] or 'NAME' in e[1] for e in errors(a)),errors(a);s.close()

def symlinks():
 p=fixture('symlink',{'main.ab':'import "app/server/main.ab"\nfun main: int = picked()\n','real/app/server/main.ab':'import "../../lib/lib.ab"\nfun picked: int = fromLexical()\n','lib/lib.ab':'fun fromLexical: int = 42\n','real/lib/lib.ab':'fun wrong: string = "wrong"\n'})
 link=p/'app/server';link.parent.mkdir(exist_ok=True)
 if not link.exists():link.symlink_to(p/'real/app/server',target_is_directory=True)
 s=Session(p);a=s.analyze();assert not errors(a),errors(a);assert any(d['uri']==(p/'lib/lib.ab').as_uri() for d in a['documents']);s.close()

def negative_protocol():
 p=fixture('bad-protocol',{'main.ab':'fun main: int = 0\n'})
 s=Session(p)
 r=s.rpc('document/open',{'uri':'https://invalid/main.ab','version':1,'text':'fun main: int = 1\n'});assert r['error']['code']=='invalid_params'
 r=s.rpc('initialize',{});assert r['error']['code']=='already_initialized'
 r=s.rpc('analyze',{'roots':[str(p/'main.ab'),str(p/'other.ab')]})['result'];assert not r['complete'] and r['issues']
 s.close()

def packages():
 p=fixture('packages',{'main.ab':'import github("fixture/locked")\nfun main: int = answer()\n'})
 package=p/'.abla/packages/locked';package.mkdir(parents=True,exist_ok=True)
 fields={'name':'locked','provider':'git','identity':'github:fixture/locked','source':'https://github.com/fixture/locked.git','selector-kind':'head','selector':'HEAD','revision':'a'*40,'digest':'b'*40,'entry':'src/locked.ab'}
 (p/'abla.lock').write_text('version = 2\n\n[[package]]\n'+''.join(f'{k} = {json.dumps(v)}\n' for k,v in fields.items()))
 for name,value in [('revision',fields['revision']),('digest',fields['digest']),('source-url',fields['source'])]:
  (package/name).write_text(value)
 (package/'entry.ab').write_text('fun answer: int = 42\n')
 s=Session(p);a=s.analyze();assert not errors(a),errors(a)
 assert any(d['uri']==(package/'entry.ab').as_uri() for d in a['documents'])
 (package/'revision').write_text('c'*40)
 b=s.analyze();assert any('PACKAGE' in e[1] for e in errors(b)),errors(b);assert not b['complete']
 s.close()
 p=fixture('dynamic-provider',{'main.ab':'compile fun dependency(): ImportSource = github("fixture/locked")\nimport dependency()\nfun main: int = 0\n'})
 s=Session(p);a=s.analyze();assert any(e[1]=='E_ANALYSIS_CT_REQUIRED' for e in errors(a)),errors(a);assert not a['complete'];s.close()
 p=fixture('shadowed-provider',{'main.ab':'val github = (name: string) -> name\nimport github("fixture/locked")\nfun main: int = 0\n'})
 s=Session(p);a=s.analyze();assert any(e[1]=='E_ANALYSIS_CT_REQUIRED' for e in errors(a)),errors(a);s.close()

def contract_surface():
 p=fixture('contract',{'main.ab':'import contract "api.ab" as api\nfun main: int = 0\n', 'api.ab':'private fun implementation: int = missing()\nfun remote(value: int): int = implementation() + value\n'})
 s=Session(p);a=s.analyze();assert not errors(a),errors(a)
 d=doc(a,p/'api.ab');assert not any(x['name']=='implementation' for x in d['symbols'])
 assert all('declarationId' not in x and 'type' not in x for x in occurrence(d,'implementation')),d['occurrences'];s.close()

def disk_revision():
 p=fixture('disk-revision',{'main.ab':'import "dep.ab"\nfun main: int = answer()\n','dep.ab':'fun answer: int = 42\n'})
 s=Session(p);a=s.analyze();assert a['complete']
 (p/'dep.ab').write_text('fun answer: int = 43\n')
 result=s.rpc('refactor/validate',{'baseRevision':a['revision'],'edits':[],'invariants':['no-new-errors']})['result']
 assert not result['valid'] and 'revision' in result['reason'],result
 current=s.analyze()
 source=(p/'main.ab').read_text()
 result=s.rpc('refactor/validate',{'baseRevision':current['revision'],'edits':[{'uri':(p/'main.ab').as_uri(),'start':0,'end':len(source.encode()),'newText':'val pending = #42\nfun main: int = pending\n'}],'invariants':['no-new-errors']})['result']
 assert not result['valid'] and 'incomplete' in result['reason'],result
 s.close()

for test in [simple,alias_private,generic_fields,no_eval,strict,symlinks,negative_protocol,packages,contract_surface,disk_revision]:
 if os.environ.get('ANALYSIS_TEST_FILTER') and test.__name__ not in os.environ['ANALYSIS_TEST_FILTER'].split(','):continue
 test();print('ok',test.__name__,flush=True)
print('analysis graph: protocol fixtures passed',flush=True)
