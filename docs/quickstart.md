# Quickstart

Create an interview from your backend, send the candidate to the hosted page
(or embed it), and read the evaluation once it is `completed`.

Everything below runs in **test mode**: use a `beai_test_` API key and no real
avatar provider is contacted. A scripted mock interview runs as soon as the
candidate session starts and produces a fabricated BARS evaluation, so you can
integrate end to end without a person on camera.

> This page is executed by CI (`api/tests/Feature/PublicApi/QuickstartTest.php`).
> Every block tagged `quickstart-step=N` runs, in order, against a test-mode
> organization and must end with the interview `completed`. Placeholders
> `{{LIKE_THIS}}` are filled from your own values or from earlier responses.

Paths are relative to your API base URL (`https://api.beai.example`, plus the
`/api` mount of the deployment you were given).

## 1. Create the interview

`POST /v1/interviews` with your test key. The response carries the one-time
`session_token` and the `hosted_url` to send to the candidate.

```http quickstart-step=1 expect=201 capture=interview.id:INTERVIEW_ID,session_token:SESSION_TOKEN assert=interview.status=pending,interview.livemode=false
POST /v1/interviews
Authorization: Bearer {{API_KEY}}
Content-Type: application/json

{
  "project_id": "{{PROJECT_ID}}",
  "candidate": {
    "candidate_ref": "quickstart-candidate-001",
    "email": "candidate@example.com",
    "display_name": "Quickstart Candidate"
  },
  "metadata": { "ats_application_id": "A-1001" }
}
```

Send `hosted_url` to the candidate, or pass `session_token` to the embed SDK
(see [Embed](#embed-optional)).

## 2. The candidate opens the link

The hosted page (and the embed iframe) does this for the candidate: it
exchanges the single-use session token for a short-lived candidate token.
You never call this yourself; it is shown so the whole flow is executable.

```http quickstart-step=2 expect=200 capture=access_token:CANDIDATE_TOKEN
GET /embed/exchange?token={{SESSION_TOKEN}}
```

## 3. The candidate starts the interview

In test mode the mock provider plays the whole interview and scores it.

```http quickstart-step=3 expect=201 assert=provider=mock
POST /candidate/interview/start
Authorization: Bearer {{CANDIDATE_TOKEN}}
```

## 4. Wait for `completed`

Poll the interview (or subscribe to the `evaluation` webhook). Scoring is
asynchronous in production; the test-mode run finishes immediately.

```http quickstart-step=4 expect=200 assert=status=completed
GET /v1/interviews/{{INTERVIEW_ID}}
Authorization: Bearer {{API_KEY}}
```

## 5. Read the evaluation

```http quickstart-step=5 expect=200 assert=status=completed
GET /v1/interviews/{{INTERVIEW_ID}}/scoring
Authorization: Bearer {{API_KEY}}
```

The response holds one entry per competency under `competencies`, each with a
`score`, a `reliability` between 0 and 1, and exactly three `behaviors`.

## Embed (optional)

Instead of redirecting to `hosted_url`, mount the interview in your page. This
snippet is illustrative and is **not** executed by CI.

```html
<div id="beai"></div>
<script src="https://cdn.beai.example/embed.iife.js"></script>
<script>
  const embed = BEAI.mount({
    container: '#beai',
    token: '<session_token from step 1>',
    onCompleted: () => console.log('interview completed'),
  })
  embed.start()
</script>
```
