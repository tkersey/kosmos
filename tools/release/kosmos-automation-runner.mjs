import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {appendFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {KosmosProposalClient} from './kosmos-proposal-github.mjs';
import {githubCommand} from './github.mjs';
import {jobPermissions} from './app-token.mjs';
import {parseEvidenceJson} from './evidence-json.mjs';
import {readRegular} from './review-owner.mjs';
import {readReviewResult} from './review-result.mjs';
import {automationMode} from './review-observer.mjs';
import {reportKosmosReview} from './review-check.mjs';
import {kosmosPreparationPlan} from './kosmos-preparation-plan.mjs';
import {readKosmosPreparation} from './kosmos-preparation-artifact.mjs';
import {nativeCandidateBinding} from './kosmos-proposal.mjs';
import {manifestOperations, sourceManifest} from './kosmos-native-manifest.mjs';
import {proposeKosmos, promoteKosmos, reconcileKosmosProposals, recoverProposalMetadata} from './kosmos-proposal.mjs';
import {createKosmosPromotionAdmission} from './kosmos-promotion-admission.mjs';
import {admitOwnerResume, reportAutomationStatus} from './kosmos-proposal-authority.mjs';
import {appActor, currentKosmosSource, kosmosBoundaryOperations, originalKosmosQualification,
  observationPages, preparationPulls, promotionRequirements, storedKosmosCandidate, admitUnproposedKosmos, retireKosmosProposal, frozenKosmosCandidate} from './kosmos-release-observation.mjs';

function writerIdentity(identity) {
  assert.equal(identity.repository, 'tkersey/kosmos'); assert.equal(identity.repositoryId, 1251308461);
  assert.equal(identity.role, 'writer'); assert.deepEqual(identity.permissions, jobPermissions.writer);
  assert.ok(Date.parse(identity.expiresAt) > Date.now(), 'repository writer credential expired');
}

function reason(error) {
  return String(error.message).slice(0, 12000);
}

export function automationOperations({client, command, native, actor}) {
  return {
    recover: pull => recoverProposalMetadata({pull, actor, client,
      readCandidate: head => storedKosmosCandidate(head, {client, command, native, actor}),
      admitRetirement: retireKosmosProposal({client, command, native, actor}),
      admitResume: value => admitOwnerResume(value, client)}),
    plan: (source,frozen=null) => kosmosPreparationPlan({source,client,command,native,actor,frozen}),
    freeze: (pull,source) => frozenKosmosCandidate(pull,source,{client,command}),
    preparation: selection => readKosmosPreparation(selection,command),
    retire: retireKosmosProposal({client, command, native, actor}),
    orphan: admitUnproposedKosmos({client, command, native, actor}),
    resume: value => admitOwnerResume(value, client),
    propose: value => proposeKosmos({...value, actor, client}),
    promote: value => promoteKosmos({...value, actor, client}),
    qualification: head => originalKosmosQualification(head, command),
    requirements: (base, appId) => promotionRequirements(base, appId, client),
    promotion: options => createKosmosPromotionAdmission({...options, client, command,
      authenticateReview: subject => readReviewResult({repository: 'tkersey/kosmos', ...subject}, command)}),
  };
}

export async function runKosmosAutomation({controlCommit, identity = null, native, configuredMode = 'off'}, {
  client = new KosmosProposalClient(), command = githubCommand,
  actorReader = appActor, sourceReader = currentKosmosSource, pause = reconcileKosmosProposals,
  reportReview = reportKosmosReview, reportStatus = reportAutomationStatus,
  operations = automationOperations,
} = {}) {
  assert.match(controlCommit, /^[0-9a-f]{40}$/);
  assert.equal(typeof native?.read, 'function'); assert.equal(typeof native?.facts, 'function');
  let actor = null, pauses = [];
  if (identity !== null) {
    writerIdentity(identity); actor = await actorReader(identity, command);
    try { pauses = (await pause({actor, client})).results; }
    catch (error) { return {status: 'blocked', pauseVerified: false, reason: reason(error)}; }
  }
  const observed = {pauses, checks: [], pauseVerified: actor !== null};
  let currentPull = null, candidate = null;
  const finish = async result => {
    const {admissionHeld = ['held', 'blocked'].includes(result.status) && !Object.hasOwn(result, 'pauseVerified'), ...initial} = result;
    let value = initial;
    const settle = async () => {
      if (actor === null) return;
      try {
        const latest = await pause({actor, client,
          hold: admissionHeld,
          number: value.status === 'landed—qualification pending' ? null : currentPull?.number ?? null});
        observed.pauses.push(...latest.results);
        observed.mode = latest.mode;
        const paused = latest.results.find(item => item.status === 'held');
        if (paused && !['held', 'blocked', 'landed—qualification pending'].includes(value.status))
          value = {...value, status: 'held', reason: paused.reason, pauseVerified: true};
        if (latest.pending.length > 0 && ['held', 'blocked', 'disabled'].includes(value.status)) {
          value = {...value, status: 'blocked', reason: [value.reason, 'A pending merge remains allowed by current controls; pause is not acknowledged.'].filter(Boolean).join(' ')};
          observed.pauseVerified = false;
        }
        const ineffective = latest.results.find(item => item.pauseVerified === false);
        if (ineffective) {
          value = {...value, status: 'blocked', reason: [value.reason, ineffective.reason].filter(Boolean).join(' ')};
          observed.pauseVerified = false;
        }
      } catch (error) {
        observed.pauseVerified = false;
        value = {...value, status: 'blocked', reason: [value.reason, 'Pending merge reconciliation failed: ' + reason(error)].filter(Boolean).join(' ')};
      }
    };
    await settle();
    if (currentPull !== null && observed.mode !== 'off') {
      try { value.comment = await reportStatus({number: currentPull.number, actor, appId: identity.appId,
        state: {status: value.status, reason: value.reason ?? null, version: candidate?.version ?? null}}, client); }
      catch (error) { value.comment = {status: 'blocked', reason: reason(error)}; }
      await settle();
    }
    return {...observed, ...value, pauseVerified: observed.pauseVerified && value.pauseVerified !== false};
  };
  if (pauses.some(value => value.pauseVerified === false)) return {...observed, status: 'blocked', pauseVerified: false,
    reason: pauses.find(value => value.pauseVerified === false).reason};
  try {
    if (actor === null) assert.ok(['off', 'propose', 'promote'].includes(configuredMode), 'invalid configured automation mode');
    const mode = actor === null ? configuredMode : await automationMode(client), source = await sourceReader(client);
    const pendingVersion = native.read(await sourceManifest(client, source.commit));
    const checks = [];
    if (actor !== null) {
      const pulls = await observationPages(client, '/pulls?state=open&base=main');
      for (const pull of pulls.filter(value => value.head.repo?.id === 1251308461 && value.base.repo?.id === 1251308461)) {
        try {
          checks.push({number: pull.number, ...await reportReview({number: pull.number, appId: identity.appId},
            {client, readResult: subject => readReviewResult(subject, command)})});
        } catch (error) { checks.push({number: pull.number, status: 'blocked', reason: reason(error)}); }
      }
    }
    Object.assign(observed, {mode, modeSource: actor === null ? 'workflow configuration' : 'live repository variable',
      source, pendingVersion, checks});
    if (actor === null) {
      const releases = await observationPages(client, '/releases');
      return {...observed, status: mode === 'off' ? 'disabled' : 'blocked',
        reason: 'Repository App writer is unavailable. Source and release observations are read-only; existing auto-merge cancellation is unverified.',
        releases: releases.map(value => ({id: value.id, tag: value.tag_name, draft: value.draft, prerelease: value.prerelease}))};
    }
    const pulls = await preparationPulls(client);
    currentPull = pulls.find(pull => pull.state === 'open') ?? null;
    if (mode === 'off') return finish({status: 'disabled'});
    if (source.commit !== controlCommit) return finish({status: 'held', reason: 'Trusted control checkout is stale; observe the current main revision.'});
    const actions = operations({client, command, native, actor});
    const recovery = await actions.recover(currentPull);
    if (recovery !== null) {candidate = recovery.candidate; return finish(recovery.result);}
    const frozen=await actions.freeze(currentPull,source);
    const plan=await actions.plan(source,frozen);
    if(plan.status!=='prepare')return finish(plan);
    const original=await actions.preparation({base:source.commit,...(frozen===null?{}:{head:frozen.head}),horosRecordSha256:plan.decision.horosRecordSha256,version:plan.decision.version});
    if(original===null)return finish({status:'preparation pending',reason:'The original unprivileged native preparation must finish before proposal writes.'});
    candidate=original.candidate;
    assert.equal(candidate.base,source.commit);assert.equal(candidate.version,plan.decision.version);
    const admitCandidate=async({candidate:proposed})=>{
      const current=await sourceReader(client),accepted=await actions.plan(current,frozen);
      assert.equal(current.commit,proposed.base,'native candidate base changed');
      assert.equal(accepted.status,'prepare','current source no longer requires preparation');
      const retained=await actions.preparation({base:proposed.base,head:proposed.head,
        horosRecordSha256:accepted.decision.horosRecordSha256,version:accepted.decision.version});
      assert.ok(retained,'original native preparation disappeared');
      assert.deepEqual(retained.decisionBytes,original.decisionBytes,'preparation decision changed');
      assert.deepEqual(nativeCandidateBinding(proposed),retained.binding,'proposal differs from original native generation');
      return retained.binding;
    };
    const proposed = await actions.propose({candidate, admitCandidate, admitRetirement: actions.retire, admitResume: actions.resume, admitOrphan: actions.orphan});
    if (proposed.number !== undefined) currentPull = {number: proposed.number};
    if (proposed.status !== 'proposal open') return finish(proposed);
    const review = await reportReview({number: proposed.number, appId: identity.appId},
      {client, readResult: subject => readReviewResult(subject, command)});
    const currentMode = await automationMode(client);
    if (currentMode !== 'promote') {
      observed.mode = currentMode;
      return finish({...proposed, review});
    }
    const run = await actions.qualification(candidate.head);
    if (run === null || run.status !== 'completed') return finish({status: 'qualification pending', number: proposed.number});
    if (run.conclusion !== 'success') return finish({status: 'held', number: proposed.number,
      reason: 'The original qualification failed; preserve that result until an admitted successor exists.'});
    if (review.conclusion !== 'success') return finish({status: 'review pending', number: proposed.number, review});
    const expected = await actions.requirements(candidate.base, identity.appId);
    const admitPromotion = actions.promotion({expected, qualificationRunId: run.id, admitCandidate});
    const promoted = await actions.promote({candidate, number: proposed.number, admitPromotion, admitResume: actions.resume});
    return finish(promoted);
  } catch (error) { return finish({status: 'held', reason: reason(error)}); }
}

if (import.meta.main) {
  const [controlDirectory, toolPath, compilerPath, identityPath] = process.argv.slice(2);
  assert.ok(controlDirectory && toolPath && compilerPath && process.argv.length <= 6);
  const root = resolve(controlDirectory);
  const git = args => execFileSync('git', ['--no-replace-objects', ...args], {cwd: root, encoding: 'utf8', timeout: 30000}).trim();
  const controlCommit = git(['rev-parse', 'HEAD']);
  assert.equal(git(['status', '--porcelain=v1', '--untracked-files=no']), '', 'trusted control checkout changed');
  if (process.env.GITHUB_SHA) assert.equal(controlCommit, process.env.GITHUB_SHA);
  const identity = identityPath ? parseEvidenceJson(readRegular(resolve(identityPath), 1024 * 1024)) : null;
  const result = await runKosmosAutomation({controlCommit, identity, configuredMode: process.env.REPOSITORY_AUTOMATION || 'off', native: manifestOperations(resolve(toolPath),resolve(compilerPath))});
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY,
    `\nRepository automation observation\n\n\`\`\`json\n${JSON.stringify(result, null, 2)}\n\`\`\`\n`);
  process.stdout.write(`${JSON.stringify(result)}\n`);
  if (result.status === 'blocked' || result.comment?.status === 'blocked' ||
      result.checks?.some(check => check.status === 'blocked')) process.exitCode = 1;
}
