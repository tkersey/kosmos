import assert from 'node:assert/strict';
import test from 'node:test';
import {execFileSync} from 'node:child_process';
import {mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, copyFileSync, chmodSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, dirname} from 'node:path';
import {prepareKosmos, preparationEnvironment, nativeInvocation} from './kosmos-prepare.mjs';
import {mechanicalPaths, nativeCandidateBinding} from './kosmos-proposal.mjs';
import {metadata} from './test-support.mjs';
import {encodeRecord, sha256} from './encoding.mjs';

const executable = process.execPath, executableSha256 = sha256(readFileSync(executable));
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'kosmos-prepare-test-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const env = {...process.env, GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_AUTHOR_NAME: 'Fixture', GIT_AUTHOR_EMAIL: 'fixture@example.invalid', GIT_AUTHOR_DATE: '2026-01-01T00:00:00Z',
    GIT_COMMITTER_NAME: 'Fixture', GIT_COMMITTER_EMAIL: 'fixture@example.invalid', GIT_COMMITTER_DATE: '2026-01-01T00:00:00Z'};
  const git = (repo, args) => execFileSync('/usr/bin/git', ['-C', repo, ...args], {encoding: 'utf8', env}).trimEnd();
  const repo = join(root, 'kosmos'), upstream = join(root, 'horos');
  for (const directory of [repo, upstream]) {mkdirSync(directory); git(directory, ['init', '--quiet']);}
  const write = (directory, path, bytes) => {mkdirSync(dirname(join(directory, path)), {recursive: true}); writeFileSync(join(directory, path), bytes);};
  const sourcePaths = [...mechanicalPaths, 'README.md', 'notes/unicode ü\nname.txt'];
  for (const path of sourcePaths) write(repo, path, `base ${path}\n`);
  git(repo, ['add', '.']); git(repo, ['commit', '--quiet', '-m', 'Fixture base']);
  const base = git(repo, ['rev-parse', 'HEAD']), baseTree = git(repo, ['rev-parse', 'HEAD^{tree}']);
  write(upstream, 'README.md', 'initial\n'); git(upstream, ['add', '.']); git(upstream, ['commit', '--quiet', '-m', 'Initial']);
  const selected = git(upstream, ['rev-parse', 'HEAD']);
  write(upstream, 'README.md', 'successor\n'); git(upstream, ['add', '.']); git(upstream, ['commit', '--quiet', '-m', 'Successor']);
  const head = git(upstream, ['rev-parse', 'HEAD']), tree = git(upstream, ['rev-parse', 'HEAD^{tree}']);
  const record = metadata('horos'); record.source.commit = head; record.source.tree = tree;
  record.source.version = '1.0.1'; record.source.packageIdentity = `horos-1.0.1-${'a'.repeat(44)}`; record.tag = 'v1.0.1';
  record.qualification.run.commit = head; record.qualification.run.tree = tree;
  record.review.landing.commit = head; record.review.landing.tree = tree;
  const archive = Buffer.from('explicit synthetic native transport fixture');
  record.artifacts[0].sha256 = sha256(archive); record.artifacts[0].bytes = archive.length;
  let recordBytes = encodeRecord(record);
  const state = {calls: [], selected, mutate: null, sourceChange: false, badManifest: false, wrongResult: false,
    extraSource: false, missingOutput: false, wrongMode: false, badArchive: false};
  const options = {
    reader: {async api(path){const commit=path.split('/').at(-1);return {sha:commit,tree:{sha:git(upstream,['rev-parse',commit+'^{tree}'])}};},async verifyRepository() {}, async releases() {return [{id: 7, assets: [{name: 'release.json'}]}];},
      async forward(a,b) {try {git(upstream,['merge-base','--is-ancestor',a,b]);return true;}catch{return false;}}},
    async admitPublishedRelease({outputDirectory}) {
      mkdirSync(outputDirectory); recordBytes = encodeRecord(record);
      writeFileSync(join(outputDirectory, 'release.json'), recordBytes);
      writeFileSync(join(outputDirectory, 'source.tar'), state.badArchive ? 'corruption' : archive);
      return {id:7, record: structuredClone(record), recordSha256: sha256(recordBytes),
        payloads: new Map([['source.tar',archive]]), paths: new Map([['release.json',join(outputDirectory,'release.json')],['source.tar',join(outputDirectory,'source.tar')]]),
        admissionVerification: Buffer.from('test-only authentication')};
    },
    async cloneRepository({repository,commit,destination}) {
      execFileSync('/usr/bin/git',['clone','--quiet','--no-hardlinks',repository === 'tkersey/kosmos'?repo:upstream,destination],{env});
      git(destination,['checkout','--quiet','--detach',commit]);
    },
    async runNative({args,root:work}) {
      state.calls.push(args[0]);
      if(args[0] === 'manifest') return {stdout: encodeRecord({sha256: state.badManifest ? 'f'.repeat(64) : sha256(readFileSync(join(args[2],'build.zig.zon'))),
        version:'1.0.0',minimumCompiler:'0.17.0',horos:{commit:state.selected,url:`git+https://github.com/tkersey/horos#${state.selected}`,packageIdentity:`horos-1.0.0-${'a'.repeat(44)}`}}),stderr:Buffer.alloc(0)};
      if(args[0] === 'check') return {stdout:Buffer.alloc(0),stderr:Buffer.alloc(0)};
      assert.equal(args[0],'prepare');const input=JSON.parse(readFileSync(args[3])), output=args[4];
      for(const path of sourcePaths)write(join(output,'source'),path,readFileSync(join(args[2],path)));
      for(const path of mechanicalPaths)write(join(output,'source'),path,`prepared ${path}\n`);
      const result={schema:'kosmos-refresh-result/v1',baseCommit:base,baseTree,version:input.version,
        horosCommit:record.source.commit,horosTree:record.source.tree,horosPackageIdentity:record.source.packageIdentity,changed:[...mechanicalPaths]};
      state.mutate?.(result);
      const bytes=Buffer.from(JSON.stringify(result));write(output,'result.json',bytes);
      if(state.extraSource)write(join(output,'source'),'README.md','forged\n');
      if(state.sourceChange)write(args[2],'README.md','changed base\n');
      if(state.missingOutput)rmSync(join(output,'source/package.json'));
      if(state.wrongMode)chmodSync(join(output,'source/package.json'),0o755);
      return {stdout:state.wrongResult?Buffer.from('{}'):bytes,stderr:Buffer.alloc(0)};
    },
  };
  const decision=()=>({base,baseTree,version:'1.0.1',horosReleaseId:7,horosRecordSha256:sha256(encodeRecord(record)),
    impact:{impact:'patch',disposition:'compatible',rationale:'Explicit test-only approved native dependency refresh.',contracts:['native dependency']}});
  let counter=0;
  const input=()=>({base,baseTree,tool:{path:executable,sha256:executableSha256,sourceCommit:base},
    compiler:{path:executable,sha256:executableSha256,sourceCommit:base},outputDirectory:join(root,`output-${counter++}`),
    versionDecision:decision(),admitVersionDecision:async({decisionBytes})=>sha256(decisionBytes),
    author:{name:'Kosmos Automation',email:'fixture@example.invalid'}});
  return {root,state,record,head,selected,base,baseTree,options,input,decision,git,upstream,
    prepare:(changes={},overrides={})=>prepareKosmos({...input(),...changes},{...options,...overrides})};
}

test('prepares complete native output with deterministic Git subject and bound decision',async t=>{
  const f=fixture(t),first=await f.prepare(),second=await f.prepare();
  assert.equal(first.status,'prepared');assert.equal(first.candidate.head,second.candidate.head);
  assert.deepEqual(first.candidateBytes,second.candidateBytes);
  assert.deepEqual([...first.candidate.files.keys()],mechanicalPaths);
  assert.equal(first.candidate.author.date,'2026-01-01T00:00:00Z');
  const proof=JSON.parse(first.proofBytes);assert.deepEqual(proof.binding,nativeCandidateBinding(first.candidate));
  assert.deepEqual(f.state.calls,['manifest','prepare','check','manifest','prepare','check']);
});

test('already selected release is unchanged without decision or generation',async t=>{
  const f=fixture(t);f.state.selected=f.head;
  const result=await f.prepare({versionDecision:undefined});
  assert.equal(result.status,'unchanged');assert.deepEqual(f.state.calls,['manifest']);
});

test('own approved version preparation reuses exact selected publication without upstream movement',async t=>{
  const f=fixture(t);f.state.selected=f.head;
  f.record.source.version='1.0.0';f.record.source.packageIdentity=`horos-1.0.0-${'a'.repeat(44)}`;f.record.tag='v1.0.0';
  f.record.compatibility.impact='major';f.record.compatibility.disposition='breaking';
  const result=await f.prepare();assert.equal(result.status,'prepared');
  assert.equal(result.candidate.horos.commit,f.head);assert.equal(result.candidate.version,'1.0.1');
});

test('development pin ahead of all publications does not downgrade',async t=>{
  const f=fixture(t);f.options.reader.forward=async()=>false;
  assert.equal((await f.prepare({versionDecision:undefined})).status,'unchanged');assert.deepEqual(f.state.calls,['manifest']);
});

test('legacy releases without canonical record cannot be successor authority',async t=>{
  const f=fixture(t);f.options.reader.releases=async()=>[{id:8,assets:[{name:'source.tar'}]}];
  assert.equal((await f.prepare({versionDecision:undefined})).status,'unchanged');
});

test('admitted upstream record still must match independently cloned Git tree',async t=>{
  const f=fixture(t),tree='f'.repeat(40);
  f.record.source.tree=tree;f.record.qualification.run.tree=tree;f.record.review.landing.tree=tree;
  await assert.rejects(f.prepare(),/source tree changed/);assert.deepEqual(f.state.calls,['manifest']);
});

for(const [name,change] of [
  ['upstream breaking change',f=>{f.record.compatibility.disposition='breaking';}],
  ['upstream major change',f=>{f.record.compatibility.impact='major';}],
  ['version downgrade',f=>{f.record.source.version='0.9.9';f.record.source.packageIdentity=`horos-0.9.9-${'a'.repeat(44)}`;f.record.tag='v0.9.9';}],
  ['native manifest mismatch',f=>{f.state.badManifest=true;}],
  ['admitted source corruption',f=>{f.state.badArchive=true;}],
])test(`rejects ${name} before native generation`,async t=>{
  const f=fixture(t);change(f);await assert.rejects(f.prepare());assert.deepEqual(f.state.calls,['manifest']);
});

for(const [name,change] of [
  ['unapproved output',f=>{f.state.extraSource=true;}],
  ['changed source base',f=>{f.state.sourceChange=true;}],
  ['missing generated file',f=>{f.state.missingOutput=true;}],
  ['changed executable mode',f=>{f.state.wrongMode=true;}],
  ['native result substitution',f=>{f.state.wrongResult=true;}],
  ['changed-set omission',f=>{f.state.mutate=value=>{value.changed.pop();};}],
  ['wrong transitive source',f=>{f.state.mutate=value=>{value.horosCommit='f'.repeat(40);};}],
])test(`rejects ${name} without candidate export`,async t=>{
  const f=fixture(t);change(f);await assert.rejects(f.prepare());
});

test('tool source and version authority bind exact source and selected release',async t=>{
  const f=fixture(t),input=f.input();
  await assert.rejects(f.prepare({tool:{...input.tool,sourceCommit:'f'.repeat(40)}}),/accepted source base/);
  await assert.rejects(f.prepare({admitVersionDecision:async()=>undefined}),/not authenticated/);
  await assert.rejects(f.prepare({versionDecision:{...f.decision(),base:'f'.repeat(40)}}));
  await assert.rejects(f.prepare({versionDecision:{...f.decision(),horosRecordSha256:'f'.repeat(64)}}));
  await assert.rejects(f.prepare({versionDecision:{...f.decision(),version:'0.9.9'}}),/own version downgrade/);
});

test('native process environment and platform sandbox exclude credentials and host home',()=>{
  const root='/private/tmp/isolated',env=preparationEnvironment(root);
  for(const key of ['GH_TOKEN','GITHUB_TOKEN','SSH_AUTH_SOCK','AWS_SECRET_ACCESS_KEY'])assert.equal(env[key],undefined);
  assert.equal(env.HOME,`${root}/home`);assert.equal(env.GIT_CONFIG_GLOBAL,'/dev/null');
  const input={tool:{path:'/accepted/native'},compiler:{path:'/compiler/bin/zig'},root,args:['manifest'],platform:'darwin'};
  const mac=nativeInvocation(input);assert.equal(mac.file,'/usr/bin/sandbox-exec');
  assert.match(mac.args[1],/\(deny default\)/);assert.ok(!mac.args[1].includes('allow network'));
  const linux=nativeInvocation({...input,platform:'linux'});assert.equal(linux.file,'/usr/bin/bwrap');
  assert.ok(linux.args.includes('--unshare-all'));assert.ok(!linux.args.includes(process.env.HOME));
});

test('native sandbox denies host secret reads and protects source and host captures', t=>{
  const parent=mkdtempSync(join(tmpdir(),'kosmos-native-boundary-'));
  t.after(()=>rmSync(parent,{recursive:true,force:true}));
  const root=join(parent,'work');mkdirSync(root);mkdirSync(join(root,'home'));mkdirSync(join(root,'tmp'));
  const protectedPath=join(root,'protected');mkdirSync(protectedPath);
  const secret=join(parent,'host-secret'),source=join(protectedPath,'source');
  writeFileSync(secret,'synthetic credential');writeFileSync(source,'accepted source');
  const execute=(args,readOnlyPaths=[])=>{
    const invocation=nativeInvocation({tool:{path:'/bin/sh'},compiler:{path:'/usr/bin/false'},root,
      args,readOnlyPaths});
    return ()=>execFileSync(invocation.file,invocation.args,{env:invocation.env,stdio:'pipe'});
  };
  assert.throws(execute(['-c','cat "$1"','probe',secret]));
  assert.throws(execute(['-c','printf changed > "$1"','probe',source],[protectedPath]));
  assert.equal(readFileSync(source,'utf8'),'accepted source');
  assert.equal(execute(['-c','printf allowed'])().toString(),'allowed');
});

import {serializePreparation,readPreparationBytes,compactKosmosPreparation,hydrateKosmosPreparation,preparationName} from './kosmos-preparation-artifact.mjs';

test('preparation transport and compact retention preserve original native bytes and reject substitution',async t=>{
  const f=fixture(t),input=f.input(),runNative=f.options.runNative;
  f.options.runNative=async request=>{
    const result=await runNative(request),directory=join(request.root,'host-captures',`execution-${request.ordinal}`);
    mkdirSync(directory,{recursive:true});writeFileSync(join(directory,'stdout.bin'),result.stdout);writeFileSync(join(directory,'stderr.txt'),result.stderr);
    return result;
  };
  const result=await prepareKosmos(input,f.options);
  const bytes=serializePreparation(result,{controlCommit:f.base,runId:31},input.outputDirectory);
  const decoded=readPreparationBytes(bytes,{base:f.base,head:result.candidate.head});
  assert.deepEqual(decoded.candidate.files,result.candidate.files);
  assert.deepEqual(decoded.candidate.nativeResultBytes,result.candidate.nativeResultBytes);
  const run={id:31,repository:{id:1251308461},head_repository:{id:1251308461},run_attempt:1,
    head_branch:'main',head_sha:f.base,status:'completed',conclusion:'success',event:'schedule',path:'.github/workflows/repository-preparation.yml'};
  const job={id:32,name:'Native candidate preparation',run_id:31,run_attempt:1,head_sha:f.base,status:'completed',conclusion:'success',
    labels:['ubuntu-24.04'],started_at:'2026-01-01T00:00:00Z',completed_at:'2026-01-01T00:01:00Z',
    steps:['Compile accepted native preparation tool','Generate frozen native candidate','Upload original preparation evidence']
      .map(name=>({name,status:'completed',conclusion:'success'}))};
  const artifact={id:33,name:preparationName(f.base,result.candidate.head),workflow_run:{id:31,repository_id:1251308461,
    head_repository_id:1251308461,head_sha:f.base},size_in_bytes:bytes.length,digest:`sha256:${sha256(bytes)}`};
  const workflow={path:run.path,commit:f.base,sha256:'d'.repeat(64)};
  const compact=compactKosmosPreparation({bytes,run,job,artifact,workflow});
  assert.deepEqual(hydrateKosmosPreparation(compact,result.candidate.files).bytes,bytes);
  const changed=new Map(result.candidate.files);changed.set(mechanicalPaths[0],Buffer.from('forged'));
  assert.throws(()=>hydrateKosmosPreparation(compact,changed));
  const forged=structuredClone(compact);forged.run.run_attempt=2;
  assert.throws(()=>hydrateKosmosPreparation(forged,result.candidate.files));
  const transport=JSON.parse(bytes);transport.captures[0].stdout=Buffer.from('forged').toString('base64');
  assert.throws(()=>readPreparationBytes(Buffer.from(`${JSON.stringify(transport)}\n`)));
  const malformed=Buffer.from(bytes.toString().replace('"schema":','"schema":"duplicate","schema":'));
  assert.throws(()=>readPreparationBytes(malformed));
});

function squashCounterpart(f){
  const tree=f.git(f.upstream,['rev-parse',`${f.selected}^{tree}`]);
  const commit=f.git(f.upstream,['-c','commit.gpgsign=false','commit-tree',tree,'-m','Equivalent published squash']);
  f.record.source.commit=commit;f.record.source.tree=tree;
  f.record.source.version='1.0.0';f.record.source.packageIdentity=`horos-1.0.0-${'a'.repeat(44)}`;f.record.tag='v1.0.0';
  f.record.qualification.run.commit=commit;f.record.qualification.run.tree=tree;
  f.record.review.landing.commit=commit;f.record.review.landing.tree=tree;
  return {commit,tree};
}

test('required publication counterpart receives full native metadata preparation and fresh candidate',async t=>{
  const f=fixture(t),counterpart=squashCounterpart(f),result=await f.prepare();
  assert.equal(result.status,'prepared');assert.equal(result.candidate.horos.commit,counterpart.commit);
  assert.equal(result.candidate.horos.tree,counterpart.tree);assert.notEqual(result.candidate.horos.commit,f.selected);
  assert.deepEqual(f.state.calls,['manifest','prepare','check']);assert.equal(result.candidate.files.size,6);
  assert.equal(JSON.parse(result.candidate.nativeResultBytes).horosCommit,counterpart.commit);
});
test('equivalent published spelling alone causes no native normalization',async t=>{
  const f=fixture(t);squashCounterpart(f);
  const result=await f.prepare({versionDecision:undefined});assert.equal(result.status,'unchanged');
  assert.equal(result.selected.commit,f.selected);assert.deepEqual(f.state.calls,['manifest']);
});
test('source equivalence cannot authorize an upstream package version downgrade',async t=>{
  const f=fixture(t);squashCounterpart(f);f.record.source.version='0.9.0';f.record.tag='v0.9.0';
  f.record.source.packageIdentity=`horos-0.9.0-${'a'.repeat(44)}`;
  await assert.rejects(f.prepare(),/upstream version downgrade/);assert.deepEqual(f.state.calls,['manifest']);
});

test('native generation consumes the exact admitted decision without rediscovering a newer upstream',async t=>{
  const f=fixture(t),calls=[];f.options.reader.releases=async()=>assert.fail('a frozen native decision cannot rediscover newer releases');
  const admit=f.options.admitPublishedRelease;
  f.options.admitPublishedRelease=async request=>{calls.push(request.releaseId);assert.equal(request.releaseId,7);return admit(request);};
  const result=await f.prepare();assert.equal(result.candidate.horos.releaseId,7);
  assert.deepEqual(calls,[7]);assert.deepEqual(f.state.calls,['manifest','prepare','check']);
});
test('native generation rejects a different record under the frozen release identity',async t=>{
  const f=fixture(t),decision=f.decision();decision.horosRecordSha256='f'.repeat(64);
  await assert.rejects(f.prepare({versionDecision:decision}),/frozen upstream record changed/);
  assert.deepEqual(f.state.calls,['manifest']);
});
