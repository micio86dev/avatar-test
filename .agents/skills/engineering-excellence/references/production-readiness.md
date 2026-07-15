# Production Readiness

"It works on my machine" is not the bar. Production-ready software behaves correctly
and safely under real conditions, across real environments, for real users.

When applicable, production-ready software should include:

- Internationalization support — see references/i18n.md
- Accessibility — see references/accessibility.md
- SEO and Agentic SEO — see references/seo.md
- `robots.txt`, `sitemap.xml`, and `llms.txt`
- Security headers and a Content Security Policy (CSP) — see references/security.md
- Compression and caching
- Health endpoints
- Structured logging
- Monitoring hooks
- Docker, when beneficial — see references/docker.md
- CI/CD — see references/ci.md
- Environment-specific configuration — see references/environments.md

## "When applicable" matters

Not every project needs every item. A CLI tool has no `sitemap.xml`; an internal
service may not need SEO. Apply the list with judgment: include what the product's
context genuinely requires, and consciously decide (rather than silently skip) what
it does not. This checklist is a prompt for that decision, not a mandate to implement
all of it.
