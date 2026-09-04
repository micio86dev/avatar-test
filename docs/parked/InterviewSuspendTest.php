<?php

declare(strict_types=1);

/**
 * POST /api/candidate/interview/suspend — pause that actually stops the meter.
 *
 * WHY THIS ENDPOINT EXISTS
 * ------------------------
 * Pausing used to mute the CANDIDATE's microphone and nothing else
 * (`useInterviewSession.ts:pause()` → `provider.setMicMuted(true)`). Two
 * consequences, both observed:
 *
 *   1. The avatar kept its turn and kept talking, because nothing ever
 *      interrupted it. A pause the interviewer talks through is not a pause.
 *   2. The provider conversation stayed open. Tavus and HeyGen bill live
 *      conversation minutes, so a candidate who stepped away for ten minutes
 *      was billed for ten minutes of an interview nobody was having.
 *
 * The only way to stop the second one is to stop the session. So pause tears
 * the provider session down and resume issues a fresh one.
 *
 * WHAT MAKES THAT CHEAP RATHER THAN DRASTIC
 * -----------------------------------------
 * Every hard part already existed for the RESUME path. `/start` on an
 * `in_corso` session already tears down the old provider ref, harvests its
 * transcript first, closes the live-clock stretch and issues a fresh token —
 * and `OpeningTextComposer` already has a `resume` variant written for exactly
 * this ("a fresh provider session re-issued for an in-progress competency").
 *
 * So this endpoint is the FIRST HALF of that path and nothing more: harvest,
 * close the stretch, tear down, forget the ref. The competency stays
 * `in_corso` with its transcript intact, which is precisely the state `/start`
 * already knows how to resume.
 *
 * WHAT IT MUST NOT DO
 * -------------------
 * End the competency. A paused interview is not a finished one: no
 * `ended_at`, no scoring dispatch, no participant transition. Those belong to
 * `/end` and a pause that reached them would score a candidate on half an
 * answer.
 */

use App\Models\AvatarTemplate;
use App\Models\BarsIndicator;
use App\Models\Competency;
use App\Models\InterviewSession;
use App\Models\InterviewSessionLivePeriod;
use App\Models\Organization;
use App\Models\Participant;
use App\Models\Project;
use App\Models\Role;
use App\Support\Jwt\CandidateTokenFactory;
use App\Support\Tenancy\TenantResolver;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Http;
use Illuminate\Support\Facades\Queue;

uses(RefreshDatabase::class);

/**
 * Self-contained fixtures.
 *
 * Pest helper functions are plain globals declared by whichever file happens
 * to be loaded, so borrowing `startProjectWithCompetencies()` from
 * `InterviewStartTest.php` works under a full-suite run and fails under
 * `pest tests/Feature/C7a/InterviewSuspendTest.php`. A test that only passes
 * when run beside another file is a test nobody can debug in isolation.
 */
function suspendTavusFake(): array
{
    return [
        '*tavusapi*/v2/conversations*' => Http::response([
            'conversation_id' => 'conv-suspend-'.uniqid(),
            'conversation_url' => 'https://tavus.io/conv-suspend',
        ], 200),
        '*tavusapi*/v2/conversations/*' => Http::response([], 200),
    ];
}

function suspendOrgWithProject(): array
{
    $org = Organization::factory()->create();

    $resolver = app(TenantResolver::class);
    $resolver->setOrgId($org->id);
    $resolver->setBypass(false);

    $template = AvatarTemplate::create([
        'name' => 'Suspend tavus '.uniqid(),
        'provider' => 'tavus',
        'config' => [],
    ]);

    $project = Project::factory()->create([
        'status' => 'active',
        'provider_override' => 'tavus',
        'avatar_template_id' => $template->id,
    ]);

    // firstOrCreate, not create: `framework_roles.code` is globally unique and
    // two fixtures in one test (the owner and the intruder) can draw the same
    // role code from the factory.
    $role = Role::where('code', $project->role_code)->first()
        ?? Role::factory()->create(['code' => $project->role_code]);

    for ($i = 0; $i < 2; $i++) {
        $competency = Competency::factory()->create();

        DB::table('project_competencies')->insert([
            'project_id' => $project->id,
            'competency_id' => $competency->id,
            'position' => $i,
        ]);

        $indicator = new BarsIndicator;
        $indicator->forceFill([
            'role_id' => $role->id,
            'competency_id' => $competency->id,
            'text' => ['en' => "Suspend fixture indicator {$i}"],
            'anchor_5' => ['en' => "Excellent {$i}"],
            'anchor_3' => ['en' => "Adequate {$i}"],
            'anchor_1' => ['en' => "Insufficient {$i}"],
            'position' => 0,
        ]);
        $indicator->save();
    }

    return [$org, $project];
}

function suspendParticipant(Organization $org, Project $project): Participant
{
    $participant = new Participant;
    $participant->forceFill([
        'organization_id' => $org->id,
        'project_id' => $project->id,
        'candidate_ref' => 'suspend-'.uniqid(),
        'display_name' => 'Suspend Test Candidate',
        'email' => uniqid('cand-').'@example.test',
        'status' => 'in_attesa',
    ]);
    $participant->save();

    return $participant->fresh();
}

/**
 * A live interview, one competency in, with a real provider ref persisted.
 *
 * Driven through the actual `/start` endpoint rather than hand-built rows: the
 * thing under test is what happens to a session the product itself created,
 * and a fixture that assembles its own would not exercise the live-clock
 * stretch this endpoint has to close.
 *
 * @return array{session: InterviewSession, token: string}
 */
function suspendLiveSession(): array
{
    Http::fake(suspendTavusFake());
    Queue::fake();

    [$org, $project] = suspendOrgWithProject();
    $participant = suspendParticipant($org, $project);
    $token = CandidateTokenFactory::mintCandidateToken($participant);

    test()->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/start')
        ->assertStatus(201);

    app(TenantResolver::class)->setOrgId($org->id);
    app(TenantResolver::class)->setBypass(false);

    $session = InterviewSession::where('participant_id', $participant->id)->firstOrFail();

    expect($session->status)->toBe('in_corso');
    expect($session->provider_session_ref)->not->toBeNull();

    return ['session' => $session, 'token' => $token];
}

test('suspend tears the provider session down so the meter stops', function (): void {
    ['session' => $session, 'token' => $token] = suspendLiveSession();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertOk();

    // The ref is what a live provider conversation IS, from this side. Null
    // means there is nothing left running and nothing left to bill.
    expect($session->fresh()->provider_session_ref)->toBeNull();
});

test('suspend leaves the competency in_corso and unscored', function (): void {
    ['session' => $session, 'token' => $token] = suspendLiveSession();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertOk();

    $fresh = $session->fresh();

    // A pause is not an ending. `/end` owns `ended_at`, the status transition
    // and the scoring dispatch; reaching any of them from here would score a
    // candidate on the half of an answer they had given when they stepped away.
    expect($fresh->status)->toBe('in_corso');
    expect($fresh->ended_at)->toBeNull();
});

test('suspend closes the live stretch, so paused time is not billed as interview time', function (): void {
    ['session' => $session, 'token' => $token] = suspendLiveSession();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertOk();

    $open = InterviewSessionLivePeriod::where('interview_session_id', $session->id)
        ->whereNull('ended_at')
        ->count();

    // Left open, the paused minutes would be counted as live ones by every
    // sum built on this table — the exact overcount this endpoint exists to
    // prevent, recorded in BEAI's own books this time rather than the
    // provider's.
    expect($open)->toBe(0);
});

test('suspend is idempotent — a second call is a no-op, not an error', function (): void {
    // The client sends this on pause AND on page-hide. Both can fire for one
    // gesture, and a candidate must never be shown an error for pausing twice.
    ['session' => $session, 'token' => $token] = suspendLiveSession();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertOk();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertOk();

    expect($session->fresh()->status)->toBe('in_corso');
});

test('a suspended session is resumable through /start, with a fresh provider ref', function (): void {
    // The whole point. Suspend leaves exactly the state `/start` already knows
    // how to resume — `in_corso` with no ref — so resuming needs no new code
    // and reuses the path that already harvests transcripts and re-greets with
    // the `resume` opening variant.
    ['session' => $session, 'token' => $token] = suspendLiveSession();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertOk();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/start')
        ->assertStatus(201);

    $resumed = $session->fresh();

    expect($resumed->status)->toBe('in_corso');
    expect($resumed->provider_session_ref)->not->toBeNull();
    expect($resumed->id)->toBe($session->id);
});

test('suspend refuses a session belonging to someone else', function (): void {
    ['session' => $session] = suspendLiveSession();

    [$otherOrg, $otherProject] = suspendOrgWithProject();
    $intruder = suspendParticipant($otherOrg, $otherProject);

    // The guard caches its resolved user for the lifetime of the test, and
    // this test has ALREADY authenticated as the owner (the fixture drives a
    // real `/start`). Without this the intruder's token is never consulted and
    // the request runs as participant 1 — which would make this test pass a
    // 200 off as proof of isolation it never checked.
    resetAuthGuardState();

    $this->withHeaders(['Authorization' => 'Bearer '.CandidateTokenFactory::mintCandidateToken($intruder)])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertNotFound();

    // Untouched: an unauthorized call must not be able to hang up someone
    // else's interview. Read back under the OWNER's tenant, since the
    // intruder's fixture left the resolver pointing at their organization.
    app(TenantResolver::class)->setOrgId($session->organization_id);

    expect($session->fresh()->provider_session_ref)->not->toBeNull();
});

test('suspend refuses a competency that has already ended', function (): void {
    /**
     * `/end` guards on `status !== 'in_corso'` and answers 409; suspend took
     * any owned session. `ParticipantStatusGuard` gates the PARTICIPANT, not
     * the session, so a candidate mid-interview could send the id of a
     * competency that already finished — re-harvesting a transcript `/end` had
     * already written and tearing down a provider session that was already
     * gone.
     *
     * Not destructive, as it happens: the harvest rewrites the same
     * authoritative copy and the teardown is a no-op. But an unguarded write
     * path whose sibling has a documented guard is a defect waiting for the
     * next caller.
     */
    ['session' => $session, 'token' => $token] = suspendLiveSession();

    app(TenantResolver::class)->setOrgId($session->organization_id);
    $session->forceFill(['status' => 'completed'])->save();

    $this->withHeaders(['Authorization' => 'Bearer '.$token])
        ->postJson('/api/candidate/interview/suspend', ['session_id' => $session->id])
        ->assertStatus(409);

    // The provider ref survives: a refused request must change nothing.
    expect($session->fresh()->provider_session_ref)->not->toBeNull();
});
