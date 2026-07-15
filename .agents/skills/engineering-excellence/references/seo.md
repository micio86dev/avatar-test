# SEO & Agentic Discoverability

Discoverability applies to public-facing applications and websites. Content behind
authentication — administration panels, dashboards, and authenticated areas — should
never be indexed (see references/environments.md).

## Search Engine Optimization

For public-facing applications:

- Generate proper metadata (title, description, and social/Open Graph tags).
- Generate canonical URLs to consolidate duplicate or parameterized pages.
- Generate `sitemap.xml`.
- Generate `robots.txt`.
- Support structured metadata (for example, Schema.org / JSON-LD) when appropriate.
- Avoid duplicate content.

## Agentic SEO (AI discoverability)

Search engines are no longer the only consumers of public content — AI systems and
agents increasingly read, summarize, and act on it. Optimize for both.

For public-facing websites:

- Generate `llms.txt` when appropriate.
- Generate `llms-full.txt` when supported.
- Ensure content is easily consumable by AI systems.
- Prefer semantic HTML so structure and meaning are machine-readable.
- Optimize discoverability for both traditional search engines and AI agents.

## Environment awareness

Indexing directives depend on the deployment environment. Non-production
environments must not be indexed. See references/environments.md.
