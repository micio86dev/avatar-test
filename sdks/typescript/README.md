# @beai/sdk@0.57.1

A TypeScript SDK client for the api.beai.example API.

## Usage

First, install the SDK from npm.

```bash
npm install @beai/sdk --save
```

Next, try it out.


```ts
import {
  Configuration,
  ExportApi,
} from '@beai/sdk';
import type { PublicApiExportsIndexRequest } from '@beai/sdk';

async function example() {
  console.log("🚀 Testing @beai/sdk SDK...");
  const config = new Configuration({ 
    // Configure HTTP bearer authorization: apiKey
    accessToken: "YOUR BEARER TOKEN",
  });
  const api = new ExportApi(config);

  const body = {
    // string | Opaque pagination cursor from a previous page\'s next_cursor. Omit for the first page. A present but malformed value answers 400 invalid_cursor. (optional)
    cursor: cursor_example,
    // number | Page size, 1-100 (default 25). Out of range answers 400 validation_failed. (optional)
    limit: 56,
  } satisfies PublicApiExportsIndexRequest;

  try {
    const data = await api.publicApiExportsIndex(body);
    console.log(data);
  } catch (error) {
    console.error(error);
  }
}

// Run the test
example().catch(console.error);
```


## Documentation

### API Endpoints

All URIs are relative to *https://api.beai.example/v1*

| Class | Method | HTTP request | Description
| ----- | ------ | ------------ | -------------
*ExportApi* | [**publicApiExportsIndex**](docs/ExportApi.md#publicapiexportsindex) | **GET** /exports | 
*ExportApi* | [**publicApiExportsShow**](docs/ExportApi.md#publicapiexportsshow) | **GET** /exports/{id} | 
*ExportApi* | [**publicApiExportsStore**](docs/ExportApi.md#publicapiexportsstore) | **POST** /exports | 
*HealthApi* | [**publicApiHealth**](docs/HealthApi.md#publicapihealth) | **GET** /health | Return the literal, non-localized &#x60;{\&quot;status\&quot;:\&quot;ok\&quot;}&#x60; body the contract requires
*InterviewApi* | [**publicApiInterviewsAnswers**](docs/InterviewApi.md#publicapiinterviewsanswers) | **GET** /interviews/{interview}/answers | &#x60;GET /v1/interviews/{id}/answers&#x60; — SPEC.md §3.3, same read gate as the transcript
*InterviewApi* | [**publicApiInterviewsEvents**](docs/InterviewApi.md#publicapiinterviewsevents) | **GET** /interviews/{interview}/events | &#x60;GET /v1/interviews/{id}/events&#x60; — SPEC.md §3.3, &#x60;App\\Support\\ PublicApi\\CursorPage&#x60; in its ASCENDING form (G-12: the one documented exception to &#x60;created_at desc&#x60;). &#x60;InterviewEvent.public_id&#x60; (&#x60;evt_&#x60;) is what every real row already carries — see that model\&#39;s own docblock; no participant special-cases its absence
*InterviewApi* | [**publicApiInterviewsIndex**](docs/InterviewApi.md#publicapiinterviewsindex) | **GET** /interviews | &#x60;data[]&#x60; documented as a list of &#x60;PublicInterview&#x60; objects, and &#x60;next_cursor&#x60; as the nullable string it genuinely is (step 5 review follow-up, Part B item 2) — &#x60;CursorPage::paginate()&#x60;\&#39;s own &#x60;next_cursor: string|null&#x60; PHPDoc did not survive being returned through &#x60;response()-&gt;json($rawPage)&#x60;, so the exported spec previously typed it as a non-nullable &#x60;string&#x60; and &#x60;data[]&#x60;\&#39;s items as untyped. &#x60;#[IgnoreResponse]&#x60;/&#x60;#[Response(400, ...)]&#x60; (Part B item 6) replace the incorrect auto-inferred &#x60;422 {message, errors}&#x60; this method\&#39;s own &#x60;QueryValidationException&#x60; throw produced — see &#x60;Problem::PROBLEM_SHAPE&#x60;\&#39;s own docblock (step 6 review follow-up, Part A item 6: now shared from &#x60;App\\Support\\PublicApi\\Problem&#x60; rather than a copy of the constant declared on this class)
*InterviewApi* | [**publicApiInterviewsScoring**](docs/InterviewApi.md#publicapiinterviewsscoring) | **GET** /interviews/{interview}/scoring | &#x60;GET /v1/interviews/{id}/scoring&#x60; — SPEC.md §3.3, gate: status &#x60;completed&#x60; only, else &#x60;409 scoring_not_ready&#x60;
*InterviewApi* | [**publicApiInterviewsShow**](docs/InterviewApi.md#publicapiinterviewsshow) | **GET** /interviews/{interview} | 
*InterviewApi* | [**publicApiInterviewsStore**](docs/InterviewApi.md#publicapiinterviewsstore) | **POST** /interviews | &#x60;interview&#x60; documented as the &#x60;PublicInterview&#x60; object it always is (step 5 review follow-up, Part B item 1) — &#x60;response()-&gt;json([...])&#x60;\&#39;s own inferred type only ever saw &#x60;InterviewResource::resolve()&#x60;\&#39;s loose &#x60;array&lt;string, mixed&gt;&#x60; return type, so the exported spec previously carried an untyped array here instead of a &#x60;$ref&#x60;. &#x60;#[Response(201, ...)]&#x60; (not a bare &#x60;@response&#x60; PHPDoc tag) — the PHPDoc form replaces Scramble\&#39;s ENTIRE inferred response, collapsing the real &#x60;201&#x60; this method actually returns down to a default &#x60;200&#x60;; the attribute form names the status explicitly and overlays onto the response Scramble already inferred at it, leaving the other auto-inferred statuses (&#x60;404&#x60;, &#x60;409&#x60;, &#x60;422&#x60;) untouched. &#x60;metadata&#x60;\&#39;s accepted shape (Part B item 3) is corrected at its source — &#x60;App\\Rules\\PublicApi\\Metadata::docs()&#x60; — rather than here, so &#x60;CreateInterviewRequest&#x60;\&#39;s own named schema carries the fix directly instead of an &#x60;allOf&#x60; overlay fighting the same property\&#39;s wrong type inside it
*InterviewApi* | [**publicApiInterviewsTranscript**](docs/InterviewApi.md#publicapiinterviewstranscript) | **GET** /interviews/{interview}/transcript | &#x60;GET /v1/interviews/{id}/transcript&#x60; — SPEC.md §3.3, gate: status &#x60;under_evaluation&#x60; or &#x60;completed&#x60;, else &#x60;409 transcript_not_ready&#x60; (&#x60;error&#x60; included — G-15)
*OrganizationApi* | [**publicApiOrganizationShow**](docs/OrganizationApi.md#publicapiorganizationshow) | **GET** /organization | 
*ProjectApi* | [**publicApiProjectsIndex**](docs/ProjectApi.md#publicapiprojectsindex) | **GET** /projects | SPEC.md §3.2 \&quot;Filtering on list endpoints: &#x60;status&#x60;, ...\&quot;. &#x60;role_code&#x60; and &#x60;assessment_type&#x60; are Public-API-specific additions this operation\&#39;s own contract entry lists (&#x60;openapi.yaml&#x60; &#x60;listProjects&#x60; parameters). An unrecognised value for any of the three answers &#x60;400 validation_failed&#x60; via &#x60;QueryValidationException&#x60; (G-28) — a malformed QUERY PARAMETER, never &#x60;422&#x60;
*ProjectApi* | [**publicApiProjectsShow**](docs/ProjectApi.md#publicapiprojectsshow) | **GET** /projects/{project} | &#x60;$project&#x60; is the RAW path segment (&#x60;prj_...&#x60;), resolved manually rather than through implicit Eloquent route-model binding: the existing admin &#x60;Route::apiResource(\&#39;projects\&#39;, ProjectController::class)&#x60; already binds the SAME &#x60;{project}&#x60; route parameter name to an integer id, and a second, public-id-based binding registered on the same parameter name would either collide with it or require touching &#x60;App\\Models\\Project::resolveRouteBinding()&#x60; globally — which the admin surface must never see (it keeps using integer ids). Resolving by hand here keeps the two surfaces fully independent, and &#x60;PublicId::decode()&#x60; returning &#x60;null&#x60; on ANY malformed/mismatched- prefix input, funnelled into the exact same \&quot;no row\&quot; 404 branch as a syntactically valid but unknown id, is what guarantees a mismatched prefix answers &#x60;404 not_found&#x60;, never &#x60;400&#x60; (SPEC.md §3.2)
*RecordingApi* | [**publicApiInterviewsRecording**](docs/RecordingApi.md#publicapiinterviewsrecording) | **GET** /interviews/{interview}/recording | 
*SessionTokenApi* | [**publicApiInterviewsSessionTokensStore**](docs/SessionTokenApi.md#publicapiinterviewssessiontokensstore) | **POST** /interviews/{interview}/session-tokens | 
*UsageApi* | [**publicApiUsageShow**](docs/UsageApi.md#publicapiusageshow) | **GET** /usage | 
*WebhookDeliveryApi* | [**publicApiWebhooksDeliveriesIndex**](docs/WebhookDeliveryApi.md#publicapiwebhooksdeliveriesindex) | **GET** /webhooks/deliveries | &#x60;GET /v1/webhooks/deliveries&#x60; — SPEC.md §3.6 \&quot;Delivery log\&quot;
*WebhookDeliveryApi* | [**publicApiWebhooksDeliveriesRedeliver**](docs/WebhookDeliveryApi.md#publicapiwebhooksdeliveriesredeliver) | **POST** /webhooks/deliveries/{id}/redeliver | &#x60;POST /v1/webhooks/deliveries/{id}/redeliver&#x60; — re-queues one delivery for immediate re-send. Allowed only from a terminal &#x60;delivered&#x60;/&#x60;failed_permanent&#x60;/&#x60;dead&#x60; state


### Models

- [CreateExportRequest](docs/CreateExportRequest.md)
- [CreateInterviewRequest](docs/CreateInterviewRequest.md)
- [CreateInterviewRequestCandidate](docs/CreateInterviewRequestCandidate.md)
- [InlineObject](docs/InlineObject.md)
- [InlineObject1](docs/InlineObject1.md)
- [PublicApiExportsIndex200Response](docs/PublicApiExportsIndex200Response.md)
- [PublicApiExportsIndex200ResponseDataInner](docs/PublicApiExportsIndex200ResponseDataInner.md)
- [PublicApiExportsIndex400Response](docs/PublicApiExportsIndex400Response.md)
- [PublicApiExportsIndex400ResponseErrorsInner](docs/PublicApiExportsIndex400ResponseErrorsInner.md)
- [PublicApiHealth200Response](docs/PublicApiHealth200Response.md)
- [PublicApiInterviewsAnswers200Response](docs/PublicApiInterviewsAnswers200Response.md)
- [PublicApiInterviewsAnswers200ResponseAnswersInner](docs/PublicApiInterviewsAnswers200ResponseAnswersInner.md)
- [PublicApiInterviewsEvents200Response](docs/PublicApiInterviewsEvents200Response.md)
- [PublicApiInterviewsEvents200ResponseDataInner](docs/PublicApiInterviewsEvents200ResponseDataInner.md)
- [PublicApiInterviewsIndex200Response](docs/PublicApiInterviewsIndex200Response.md)
- [PublicApiInterviewsRecording200Response](docs/PublicApiInterviewsRecording200Response.md)
- [PublicApiInterviewsScoring200Response](docs/PublicApiInterviewsScoring200Response.md)
- [PublicApiInterviewsScoring200ResponseCompetenciesValue](docs/PublicApiInterviewsScoring200ResponseCompetenciesValue.md)
- [PublicApiInterviewsScoring200ResponseCompetenciesValueBehaviorsInner](docs/PublicApiInterviewsScoring200ResponseCompetenciesValueBehaviorsInner.md)
- [PublicApiInterviewsSessionTokensStore201Response](docs/PublicApiInterviewsSessionTokensStore201Response.md)
- [PublicApiInterviewsSessionTokensStore409Response](docs/PublicApiInterviewsSessionTokensStore409Response.md)
- [PublicApiInterviewsStore201Response](docs/PublicApiInterviewsStore201Response.md)
- [PublicApiInterviewsStore409Response](docs/PublicApiInterviewsStore409Response.md)
- [PublicApiInterviewsStore409ResponseAnyOf](docs/PublicApiInterviewsStore409ResponseAnyOf.md)
- [PublicApiInterviewsStore409ResponseAnyOf1](docs/PublicApiInterviewsStore409ResponseAnyOf1.md)
- [PublicApiInterviewsTranscript200Response](docs/PublicApiInterviewsTranscript200Response.md)
- [PublicApiInterviewsTranscript200ResponseTurnsInner](docs/PublicApiInterviewsTranscript200ResponseTurnsInner.md)
- [PublicApiProjectsIndex200Response](docs/PublicApiProjectsIndex200Response.md)
- [PublicApiUsageShow200Response](docs/PublicApiUsageShow200Response.md)
- [PublicApiUsageShow200ResponseEvaluations](docs/PublicApiUsageShow200ResponseEvaluations.md)
- [PublicApiUsageShow200ResponseInterviews](docs/PublicApiUsageShow200ResponseInterviews.md)
- [PublicApiUsageShow200ResponseLlmTokens](docs/PublicApiUsageShow200ResponseLlmTokens.md)
- [PublicApiWebhooksDeliveriesIndex200Response](docs/PublicApiWebhooksDeliveriesIndex200Response.md)
- [PublicApiWebhooksDeliveriesIndex200ResponseDataInner](docs/PublicApiWebhooksDeliveriesIndex200ResponseDataInner.md)
- [PublicInterview](docs/PublicInterview.md)
- [PublicInterviewProgress](docs/PublicInterviewProgress.md)
- [PublicInterviewProgressAnyOfInner](docs/PublicInterviewProgressAnyOfInner.md)
- [PublicInterviewProgressAnyOfInnerAnswersInner](docs/PublicInterviewProgressAnyOfInnerAnswersInner.md)
- [PublicInterviewProject](docs/PublicInterviewProject.md)
- [PublicInterviewProjectFrameworkVersion](docs/PublicInterviewProjectFrameworkVersion.md)
- [PublicOrganization](docs/PublicOrganization.md)
- [PublicProject](docs/PublicProject.md)

### Authorization


Authentication schemes defined for the API:
<a id="apiKey"></a>
#### apiKey


- **Type**: HTTP Bearer Token authentication (beai_live_… | beai_test_…)

## About

This TypeScript SDK client supports the [Fetch API](https://fetch.spec.whatwg.org/)
and is automatically generated by the
[OpenAPI Generator](https://openapi-generator.tech) project:

- API version: `0.57.1`
- Package version: `0.57.1`
- Generator version: `7.25.0`
- Build package: `org.openapitools.codegen.languages.TypeScriptFetchClientCodegen`

The generated npm module supports the following:

- Environments
  * Node.js
  * Webpack
  * Browserify
- Language levels
  * ES5 - you must have a Promises/A+ library installed
  * ES6
- Module systems
  * CommonJS
  * ES6 module system


## Development

### Building

To build the TypeScript source code, you need to have Bun installed.
After cloning the repository, navigate to the project directory and run:

```bash
bun install
bun run build
```

### Publishing

Once you've built the package, you can publish it to npm:

```bash
bun publish
```

## License

[]()
