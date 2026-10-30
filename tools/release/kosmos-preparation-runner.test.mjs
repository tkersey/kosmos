import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {jobPermissions} from './app-token.mjs';
import {encodeRecord,sha256} from './encoding.mjs';
import {metadata} from './test-support.mjs';
import {discoverHorosRelease,kosmosPreparationPlan,mechanicalVersion} from './kosmos-preparation-plan.mjs';
import {planKosmosPreparation,priorPreparationAttempt,preparationStartName,generateKosmosPreparation} from './kosmos-preparation-runner.mjs';

const base='a'.repeat(40),tree='b'.repeat(40),head='c'.repeat(40),digest='d'.repeat(64),source={commit:base,tree};
const actor={id:7,login:'kosmos-release[bot]'};
function fixture(){
  const identity={repository:'tkersey/kosmos',repositoryId:1251308461,role:'observer',permissions:jobPermissions.observer,expiresAt:'2099-01-01T00:00:00Z'};
  const state={mode:'propose',source:{...source},calls:[],original:null,previous:null,pulls:[],plan:{status:'prepare',decision:{base,baseTree:tree,
    version:'9.1.1',horosReleaseId:1,horosRecordSha256:digest},decisionSha256:digest,boundarySha256:digest}};
  const client={async request({path}){assert.equal(path,'/actions/variables/REPOSITORY_AUTOMATION');return {status:200,body:{name:'REPOSITORY_AUTOMATION',value:state.mode}};}};
  const options={client,freeze:async()=>null,sourceReader:async()=>state.source,actorReader:async()=>actor,
    plan:async()=>{state.calls.push('plan');return structuredClone(state.plan);},read:async()=>{state.calls.push('read');return state.original;},
    prior:async()=>{state.calls.push('prior');return state.previous;},pulls:async()=>state.pulls,
    retire:()=>async()=>{state.calls.push('retire');if(state.unfinished)throw Error('original owner epoch is still active');}};
  const input={controlCommit:base,identity,native:{}};
  return {state,input,options,run:()=>planKosmosPreparation(input,options)};
}

test('preparation observes accepted source and starts only missing original input',async()=>{
  const f=fixture(),value=await f.run();assert.equal(value.status,'ready');assert.deepEqual(value.source,source);
  assert.deepEqual(value.actor,actor);assert.deepEqual(f.state.calls,['plan','read','prior']);
});
test('existing native preparation is reused without regeneration or retry marker',async()=>{
  const f=fixture();f.state.original={candidate:{head},run:{id:19}};
  assert.deepEqual(await f.run(),{status:'prepared',head,runId:19});assert.deepEqual(f.state.calls,['plan','read']);
});
test('prior failed generation is retained unchanged',async()=>{
  const f=fixture();f.state.previous={runId:18,status:'completed',conclusion:'failure'};
  const result=await f.run();assert.equal(result.status,'held');assert.deepEqual(result.original,f.state.previous);
});
test('source movement and disabled automation prevent preparation planning',async()=>{
  const f=fixture();f.state.source.commit=head;assert.equal((await f.run()).status,'held');
  f.state.mode='off';assert.equal((await f.run()).status,'disabled');assert.deepEqual(f.state.calls,[]);
});
for(const change of ['draft','hold','active'])test(`current ${change} proposal prevents a new native epoch`,async()=>{
  const f=fixture();f.state.pulls=[{state:'open',body:`<!-- repository-proposal/v1 ${digest} -->\n\nBase: \`${base}\`\nHead: \`${head}\`\n`,head:{sha:head},draft:change==='draft',labels:change==='hold'?[{name:'automation-hold'}]:[]}];
  if(change==='active'){f.state.unfinished=true;await assert.rejects(f.run(),/epoch/);}else assert.equal((await f.run()).status,'held');
  assert.ok(!f.state.calls.includes('prior'));
});
test('closed original epoch admits a changed source decision for preparation',async()=>{
  const f=fixture();f.state.pulls=[{state:'open',body:`<!-- repository-proposal/v1 ${digest} -->\n\nBase: \`${base}\`\nHead: \`${head}\`\n`,head:{sha:head},draft:false,labels:[]}];
  assert.equal((await f.run()).status,'ready');assert.ok(f.state.calls.includes('retire'));
});
for(const key of ['role','permissions','expiresAt'])test(`preparation refuses invalid observer ${key}`,async()=>{
  const f=fixture();f.input.identity[key]=key==='role'?'writer':key==='permissions'?{}:'2000-01-01T00:00:00Z';
  await assert.rejects(f.run());assert.deepEqual(f.state.calls,[]);
});
test('prospective mechanical impact bumps only from admitted publication and preserves pending higher version',()=>{
  const b={version:'9.1.0',record:{baseline:{source:{version:'9.1.0'}}}};
  assert.equal(mechanicalVersion(b,true),'9.1.1');assert.equal(mechanicalVersion(b,false),'9.1.0');
  b.version='10.0.0';assert.equal(mechanicalVersion(b,true),'10.0.0');b.record.baseline=null;assert.equal(mechanicalVersion(b,true),'10.0.0');
});
test('native own manifest and own reviewed boundary decide prospective dependency preparation',async()=>{
  const manifestBytes=Buffer.from('synthetic native manifest'),client={async request(){return {status:200,body:{type:'file',encoding:'base64',
    content:manifestBytes.toString('base64'),sha:createHash('sha1').update(`blob ${manifestBytes.length}\0`).update(manifestBytes).digest('hex')}};}};
  const selected={commit:'e'.repeat(40),packageIdentity:`horos-1.0.0-${'a'.repeat(44)}`};
  const native={facts:()=>({version:'9.1.0',horos:selected})},upstream={id:5,source:{...selected,commit:'f'.repeat(40)},recordSha256:digest};
  const boundary={status:'unchanged',version:'9.1.0',sha256:digest,record:{source,baseline:{source:{version:'9.1.0'}}}};
  const result=await kosmosPreparationPlan({source,client,native,actor},{boundary:async()=>boundary,discover:async value=>{assert.deepEqual(value,selected);return upstream;}});
  assert.equal(result.status,'prepare');assert.equal(result.decision.version,'9.1.1');assert.equal(result.decision.horosReleaseId,5);
  assert.equal(result.decisionSha256,sha256(encodeRecord(result.decision)));
});
test('upstream discovery authenticates canonical publications and blocks reviewed major migration',async()=>{
  const record=metadata('horos'),selected={commit:'e'.repeat(40),packageIdentity:`horos-0.1.0-${'a'.repeat(44)}`};
  const reader={async api(){return {sha:selected.commit,tree:{sha:"f".repeat(40)}};},async verifyRepository(){},async releases(){return [{id:1,assets:[{name:'release.json'}]},{id:2,assets:[{name:'source.tar'}]}];},async forward(a,b){return a===b||(a===selected.commit&&b===record.source.commit);}};
  const admit=async()=>({id:1,record,recordSha256:sha256(encodeRecord(record)),payloads:new Map()});
  const result=await discoverHorosRelease(selected,{reader,admit});assert.equal(result.id,1);
  record.compatibility.impact='major';await assert.rejects(discoverHorosRelease(selected,{reader,admit}),/major migration/);
});
test('missing original generation-start artifact cannot silently authorize another invocation',async()=>{
  const run={id:8,path:'.github/workflows/repository-preparation.yml',head_sha:base,head_branch:'main',repository:{id:1251308461},
    head_repository:{id:1251308461},status:'completed',conclusion:'failure'};
  const command=async args=>{
    const path=args[1];
    if(path.includes('/actions/artifacts?'))return Buffer.from(JSON.stringify({artifacts:[]}));
    if(path.includes('/runs?'))return Buffer.from(JSON.stringify({workflow_runs:[run]}));
    assert.ok(path.includes('/attempts/1/jobs?'));
    return Buffer.from(JSON.stringify({jobs:[{id:9,name:'Native candidate preparation',steps:[{name:'Generate frozen native candidate',started_at:'2026-01-01T00:00:00Z',status:'completed',conclusion:'failure'}]}]}));
  };
  const result=await priorPreparationAttempt({base,decisionSha256:digest},command);assert.equal(result.runId,8);assert.match(result.reason,/missing/);
});
test('preserved original start blocks equivalent generation even after artifact expiry',async()=>{
  const run={id:8,path:'.github/workflows/repository-preparation.yml',head_sha:base,run_attempt:1,repository:{id:1251308461},head_repository:{id:1251308461},status:'completed',conclusion:'failure'};
  const artifact={id:9,name:preparationStartName(digest),expired:true,workflow_run:{id:8,head_sha:base,head_branch:'main',repository_id:1251308461,head_repository_id:1251308461}};
  const command=async args=>Buffer.from(JSON.stringify(args[1].includes('/actions/artifacts?')?{artifacts:[artifact]}:run));
  assert.equal((await priorPreparationAttempt({base,decisionSha256:digest},command)).runId,8);
});
test('generation revalidates accepted decision at native invocation boundary',async()=>{
  const f=fixture(),plan=await f.run();let calls=0;
  const options={client:f.options.client,native:{},sourceReader:async()=>source,select:async()=>({...f.state.plan,decisionSha256:'f'.repeat(64)}),
    prepare:async input=>{calls++;await input.admitVersionDecision({decisionBytes:encodeRecord(plan.decision)});assert.fail('changed decision passed');}};
  await assert.rejects(generateKosmosPreparation({plan,tool:{path:'/tool',sourceCommit:base},compiler:{path:'/zig',sourceCommit:base},outputDirectory:'/unused',runId:1},options),/inputs changed/);
  assert.equal(calls,1);
});
test('preparation workflow uses read authority, original start and bounded isolated native generation',()=>{
  const text=readFileSync(new URL('../../.github/workflows/repository-preparation.yml',import.meta.url),'utf8');
  assert.match(text,/timeout-minutes: 10/);assert.match(text,/cancel-in-progress: false/);assert.match(text,/create tkersey\/kosmos observer/);
  assert.ok(!text.includes(' writer ')&&!text.includes('contents: write')&&!text.includes('pull_request_target'));
  assert.ok(text.indexOf('Compile accepted native preparation tool')<text.indexOf('REPOSITORY_APP_PRIVATE_KEY'));
  assert.ok(text.indexOf('Preserve original generation start')<text.indexOf('Generate frozen native candidate'));
  assert.match(text,/apparmor_parser --replace/);assert.match(text,/archive: false/);assert.match(text,/app-token.mjs revoke/);
});

test('frozen planner admits only the chosen publication and ignores unrelated newer failures',async()=>{
  const record=metadata('horos'),selected={commit:'e'.repeat(40),packageIdentity:`horos-0.1.0-${'a'.repeat(44)}`},calls=[];
  const reader={async api(){return {sha:selected.commit,tree:{sha:'f'.repeat(40)}};},async verifyRepository(){},
    async releases(){assert.fail('unrelated newer malformed publications are outside frozen admission');},
    async forward(a,b){return a===b||(a===selected.commit&&b===record.source.commit);}};
  const admit=async request=>{calls.push(request.releaseId);assert.equal(request.releaseId,1);
    return {id:1,record,recordSha256:sha256(encodeRecord(record)),payloads:new Map()};};
  assert.equal((await discoverHorosRelease(selected,{releaseId:1,reader,admit})).id,1);assert.deepEqual(calls,[1]);
});

test('generation revalidates the frozen selected release rather than latest discovery',async()=>{
  const f=fixture(),plan=await f.run();let admitted=false;
  const options={client:f.options.client,native:{},sourceReader:async()=>source,
    select:async input=>{assert.deepEqual(input.frozen,{base,horos:{releaseId:plan.decision.horosReleaseId,recordSha256:plan.decision.horosRecordSha256}});return f.state.plan;},
    prepare:async input=>{await input.admitVersionDecision({decisionBytes:encodeRecord(plan.decision)});admitted=true;throw Error('test native execution boundary');}};
  await assert.rejects(generateKosmosPreparation({plan,tool:{path:'/tool',sourceCommit:base},compiler:{path:'/zig',sourceCommit:base},outputDirectory:'/unused',runId:1},options),/test native execution boundary/);
  assert.equal(admitted,true);
});
