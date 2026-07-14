# BEAI (Business Evaluation AI) - Software Requirements & Architecture

## Purpose
BEAI is a configurable assessment platform used by HR departments to evaluate employees and candidates through psychometric/behavioral assessments.

## Goals
- Evaluate participants.
- Produce numerical scores.
- Support HR decisions:
  - Hiring
  - Internal development
  - Organizational redesign
  - Training recommendations

## Core Concepts

### Participant
A person taking one or more assessments.

### Assessment
A configurable test composed of questions.

### Competency Model (DICE)
All assessments map to a common competency framework (DICE).

There are approximately **18 competencies**, including:
- Customer Focus
- Critical Thinking
- ...

Each competency produces a numeric score.

## Competencies

Each competency contains:
- id
- name
- description
- low/medium/high interpretation

Example:

Customer Focus measures:
- understanding customer needs
- keeping commitments
- managing expectations

## Organizational Roles

Questions depend on the participant role.

Examples:
- Individual Contributor
- Frontline Leader
- Mid-Level Manager
- Senior Leadership

Each role has:
- different wording
- different expectations
- different evaluation

## Assessment Dimensions

Every competency can be evaluated through:

### Readiness
Current capability.

### Potential
Future capability after development.

Projects may measure either dimension.

## Project Configuration

Every customer project configures:

- competencies
- roles
- readiness/potential
- assessment list
- branding
- reminders
- deadlines

## Functional Requirements

### FR-001 Project Management
Create/update/archive projects.

### FR-002 Participant Management
- invitations
- authentication
- reminders
- progress

### FR-003 Assessment Engine
- configurable questions
- role-aware questions
- competency mapping

### FR-004 Results
Store scores and expose APIs.

### FR-005 Dashboards
HR views:
- participant status
- results
- reports

### FR-006 Multi-test Portal
Optional dashboard hosting multiple assessments.

## Suggested Domain Model

Customer
Organization
Project
Participant
Role
Competency
Question
Assessment
AssessmentSession
Answer
Score
Report

## Integrations

- REST API
- Webhooks
- Authentication
- External HR systems

## Non Functional Requirements

- GDPR
- Accessibility
- Scalability
- Audit logs
- Monitoring
- Debugging
- White-label branding

## Suggested Architecture

Frontend
- Nuxt

Backend
- Laravel

Services
- Assessment Engine
- Scoring
- Notifications
- Webhooks

Storage
- MySQL/PostgreSQL (ORM Eloquent)

## API Ideas

GET /projects
GET /participants
GET /participants/{id}
GET /results/{participantId}
POST /invite
POST /assessment/start
POST /assessment/complete

## Open Questions

- How is scoring calculated?
- Can competencies change over time?
- Versioning?
- Multiple attempts?
- Time limits?
- Localization?
- Reporting format?

## Claude Code Tasks

1. Review architecture.
2. Propose database schema.
3. Design APIs.
4. Design permission model.
5. Identify bounded contexts.
6. Suggest modular architecture.
7. Generate Laravel migrations.
8. Generate OpenAPI specification.
9. Identify risks and missing requirements.
