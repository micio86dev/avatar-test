# Acceptance scenarios

Narrative scenarios for validating the rebuild. They do not assume compatibility with legacy integrations.

---

## SA-01 — SSO ingress and first interview

**Given** a "Selezione FLL" project for Acme with 18 competencies in Italian  
**And** a candidate, Mario Rossi, not yet registered  
**When** the HR portal generates a valid SSO link and Mario opens it on desktop Chrome  
**Then** BEAI creates the candidate, requests the microphone and starts the interview  
**And** sends a progress webhook with all competencies and empty answers  

---

## SA-02 — Adaptive conversation

**Given** Mario in an interview on the INN competency  
**When** he answers the first question vaguely  
**Then** the AI asks a follow-up question on the same competency  
**When** he answers adequately  
**Then** the AI moves on to the next competency  
**And** every recorded answer generates a progress webhook update  

---

## SA-03 — Nudge on a short answer

**Given** a project with a configured nudge threshold (e.g. a minimum of 50 characters)  
**When** the candidate answers with a very short sentence  
**Then** the system issues a voice prompt to elaborate  

---

## SA-04 — Pauses between competencies

**Given** a project with a pause every 3 competencies  
**When** the candidate completes the 3rd competency  
**Then** a pause screen is shown before continuing  

---

## SA-05 — Closing and redirect

**Given** Mario completing the last competency  
**When** the interview ends  
**Then** Mario is redirected to the URL configured for the project  
**And** his status moves to "under evaluation"  
**And** an asynchronous scoring job is started  

---

## SA-06 — Successfully completed evaluation

**Given** Mario has provided sufficient answers on at least 90% of the competencies (17/18)  
**When** the evaluation job finishes  
**Then** an evaluation webhook arrives with status `completed`  
**And** the payload includes, for every competency: score, reliability, behaviors with excerpts  
**And** the admin can download the transcript and the report  

---

## SA-07 — Pending evaluation and retry

**Given** Mario has insufficient answers on too many competencies (< 90% valid)  
**When** the evaluation job finishes  
**Then** a webhook arrives with status `pending` and partial data  
**When** Mario repeats the interview (the single retry)  
**And** still does not reach the threshold  
**Then** the following webhook carries status `completed` (definitive)  

---

## SA-08 — Potential assessment

**Given** a Potential-type project with the MTG and LAT competencies  
**When** a candidate starts the interview  
**Then** for every competency 4 predefined questions are asked, followed by AI follow-ups  
**And** no standard competencies (PRS, STG, …) appear  

---

## SA-09 — Admin: full tenant cycle

**Given** an authenticated admin operator  
**When** they create an organization, a project (role ICO, 15 competencies) and a candidate  
**Then** they can generate the link, monitor status in realtime, and download the evaluation on completion  

---

## SA-10 — Remote management API

**Given** valid API credentials for the Acme tenant  
**When** the calling system creates a project and a candidate through the API  
**And** reads status and evaluation on completion  
**Then** every operation respects tenant isolation and the status gates  

---

## SA-11 — Unsupported browser

**Given** a candidate on desktop Firefox  
**When** they open the interview link  
**Then** they see a clear message instructing them to use Chrome or Edge  
**And** the interview does not start  

---

## SA-12 — Expired SSO token

**Given** an SSO link generated 2 hours ago with a 30-minute validity  
**When** the candidate opens it  
**Then** they see a "link expired" error and no interview starts  

---

## General acceptance criteria

- [ ] All scenarios SA-01 … SA-12 pass in the staging environment;
- [ ] The competency framework in `02-domain/framework/` is integrated into the evaluation engine;
- [ ] OpenAPI documentation + integration guide delivered;
- [ ] No dependency on legacy components (the router, historical username formats).
