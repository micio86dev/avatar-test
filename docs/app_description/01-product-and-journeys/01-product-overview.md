# Product overview

## What BEAI is

BEAI is a **web application** for assessing **soft skills** through an **automated voice interview**.

The candidate takes an interview with a virtual (AI) interviewer that:
- asks structured questions per competency;
- listens to the spoken answers;
- adapts the flow in real time (probing deeper or moving on to the next competency);
- at the end triggers an **asynchronous evaluation** based on behavioural scales (BARS).

## The problem it solves

Organizations need to assess transversal competencies (leadership, problem solving, collaboration, etc.) on candidates or employees in a way that is:
- **scalable** (many participants, little human supervision);
- **structured** (the same framework per role);
- **objective** (scoring against behavioural indicators defined up front).

## Actors

| Actor | Role |
|--------|-------|
| **Candidate** | Takes the voice interview through the browser |
| **Administrator** | Configures companies, projects, candidates; monitors status and results |
| **Calling system** | External HR portal or LMS that sends authenticated users and receives notifications |
| **AI engine** | Handles conversation, transcription and evaluation (internal or external to the web app) |

## Functional components of the platform

### 1. Candidate experience (the interview)

An end-to-end voice web interface:
- entry through a secure link;
- microphone setup;
- adaptive conversation with a synthetic voice;
- pauses between competencies and prompts on answers that are too short;
- closing and redirect back to the originating system.

### 2. Administration panel

An interface for internal operators or B2B customers:
- managing **Companies** (tenants);
- managing **Projects** (assessment campaigns);
- managing **Candidates** (creation, monitoring, downloading results);
- an optional **billing** module tied to completed interviews.

### 3. Integration surface

Machine-to-machine capabilities for external systems (details in `04-integration-surface/`):
- user ingress (SSO / magic link);
- APIs for managing tenants and assessments;
- progress and evaluation webhooks;
- user exit after the assessment.

## Conceptual data model

```
Company (tenant)
  └── Project (assessment configuration)
        └── Candidate (participant instance)
              ├── Answers / transcript
              └── Evaluation (once completed)
```

| Entity | Meaning |
|--------|-------------|
| **Company** | Customer organization. The tenancy and billing boundary. |
| **Project** | A campaign for a target role: competency set, language, UX options (pauses, prompts), assessment type. |
| **Candidate** | A unique participant in the context of the project. Has a **status** that evolves over the lifecycle. |

## Realtime architecture (conceptual reference)

During the interview three layers typically work together:

```
Candidate browser  ←→  Audio services (TTS/STT)  ←→  Conversational / AI engine
                              ↓
                    Notifications to external systems (webhooks)
```

**Design goal:** minimal latency in the conversation. Audio may stream directly between the browser and specialised services, with orchestration on the backend/AI side.

> The current stack (e.g. specific TTS/STT providers) is **not binding**. The experience must be equivalent: a fluid conversation, close to a phone call.

## Assessment types

See `02-domain/03-assessment-types.md`. In short:

| Type | Description |
|------|-------------|
| **Standard (readiness)** | Framework competencies for the role; adaptive AI questions |
| **Potential** | Managing and Leadership Attributes competencies only; 4 predefined questions per competency + AI follow-ups |

## Expected deliverable

A complete web platform that reproduces the **functional purpose** of the current version with:
- a redesigned UX;
- free choice of architecture and stack;
- external integrations designed from scratch (following the outline in `04-integration-surface/`).
