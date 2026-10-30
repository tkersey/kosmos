import assert from 'node:assert/strict';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {GitHubReader,githubCommand} from './github.mjs';
import {admitPublishedRelease} from './release-admission.mjs';
import {computeKosmosPublicationBoundary} from './kosmos-publication-boundary.mjs';
import {kosmosBoundaryOperations} from './kosmos-release-observation.mjs';
import {sourceManifest} from './kosmos-native-manifest.mjs';
import {encodeRecord,sha256} from './encoding.mjs';
import {prepareVersion,parseVersion} from './version.mjs';
import {selectPublishedSource,admitFrozenSource} from './kosmos-upstream-selection.mjs';

export async function discoverHorosRelease(selected,{versionPreparation=false,releaseId,command=githubCommand,
  reader=new GitHubReader('tkersey/horos',command),admit=admitPublishedRelease}={}) {
  await reader.verifyRepository();const accepted=[];
  const admitOne=async id=>{
    const directory=mkdtempSync(join(tmpdir(),'kosmos-upstream-'));
    try{
      const value=await admit({repository:'tkersey/horos',releaseId:id,outputDirectory:join(directory,'release')},command);
      assert.equal(value.id,id);assert.equal(value.record.repository.name,'tkersey/horos');
      assert.equal(value.recordSha256,sha256(value.payloads.get('release.json')??encodeRecord(value.record)));
      return {id:value.id,record:value.record,recordSha256:value.recordSha256,source:value.record.source};
    }finally{rmSync(directory,{recursive:true,force:true});}
  };
  let successor;
  if(releaseId!==undefined)successor=await admitFrozenSource(reader,selected,releaseId,admitOne);
  else{
    for(const release of await reader.releases()){
      assert.ok(Array.isArray(release.assets));if(!release.assets.some(asset=>asset.name==='release.json'))continue;
      accepted.push(await admitOne(release.id));
    }
    successor=await selectPublishedSource(reader,selected,accepted,{publicationRequired:versionPreparation});
  }
  if(successor?.source.commit===selected.commit)assert.equal(successor.source.packageIdentity,selected.packageIdentity);
  if(successor===null)return null;
  if(successor.source.commit!==selected.commit){
    assert.equal(successor.record.compatibility.disposition,'compatible','upstream breaking migration requires ordinary implementation');
    assert.notEqual(successor.record.compatibility.impact,'major','upstream major migration requires ordinary implementation');
  }
  const version=/^horos-([0-9]+\.[0-9]+\.[0-9]+)-[A-Za-z0-9_-]{44}$/.exec(selected.packageIdentity);
  assert.ok(version);const before=parseVersion(version[1]),after=parseVersion(successor.source.version);
  assert.ok(after.some((part,index)=>part>before[index]&&after.slice(0,index).every((value,i)=>value===before[i]))||
    after.every((part,index)=>part===before[index]),'upstream publication would downgrade dependency');
  return successor;
}

export function mechanicalVersion(boundary,upstreamChanged){
  if(!upstreamChanged)return boundary.version;
  if(boundary.record.baseline===null)return boundary.version;
  return prepareVersion({published:boundary.record.baseline.source.version,pending:boundary.version,declarations:['patch'],publicationRequired:true});
}

export async function kosmosPreparationPlan({source,client,native,actor,frozen=null,command=githubCommand},{
  boundary=source=>computeKosmosPublicationBoundary({source},kosmosBoundaryOperations({client,native,actor,command})),
  discover=(selected,publicationRequired)=>discoverHorosRelease(selected,{versionPreparation:publicationRequired,command,...(frozen===null?{}:{releaseId:frozen.horos.releaseId})}),
}={}){
  const manifest=native.facts(await sourceManifest(client,source.commit)),admitted=await boundary(source);
  assert.deepEqual(admitted.record.source,source);
  const upstream=await discover(manifest.horos,['ready','prepare'].includes(admitted.status)||frozen!==null);
  if(upstream===null){
    assert.notEqual(admitted.status,'prepare','own version preparation requires exact admitted upstream publication');
    return {status:admitted.status==='ready'?'publication ready':admitted.status,boundarySha256:admitted.sha256,version:admitted.version};
  }
  if(frozen!==null){
    assert.equal(frozen.base,source.commit);assert.equal(upstream.recordSha256,frozen.horos.recordSha256,'frozen upstream publication changed');
  }
  const changed=upstream.source.commit!==manifest.horos.commit,version=mechanicalVersion(admitted,changed);
  if(!changed&&version===manifest.version)return {status:admitted.status==='ready'?'publication ready':admitted.status,
    boundarySha256:admitted.sha256,version};
  const decision={base:source.commit,baseTree:source.tree,version,horosReleaseId:upstream.id,horosRecordSha256:upstream.recordSha256,
    impact:{impact:'patch',disposition:'compatible',rationale:changed?'Refresh the admitted Horos dependency and generated native contract files.':'Prepare the admitted Kosmos release version and generated native contract files.',contracts:['native dependency','package metadata']}};
  const bytes=encodeRecord(decision);
  return {status:'prepare',decision,decisionSha256:sha256(bytes),boundarySha256:admitted.sha256,upstream};
}
