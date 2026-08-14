# Tasks: Field Help on the Avatar Template Form

> Copy ported verbatim from `quint-avatar-tester`, which already carries a
> reviewed hint for all 29 fields in both locales. Rewriting it would be
> re-deciding something already decided, worse.

- [x] 1.1 `FieldSpec` gains `hintKey`, nullable.
- [x] 1.2 `ProviderFieldSpecs` populates it for all 29 fields across both providers.
- [x] 1.3 `openapi.json` resynced — the field-specs endpoint shape changes.
- [x] 2.1 `AvatarTemplateForm` renders the hint under each control; a missing hint degrades to no hint, never to a missing control.
- [x] 2.2 29 hints ported into `i18n/locales/{it,en}.json`, locale parity kept.
- [x] 2.3 Tests: hint rendered per field; a spec without a hint still renders its control.

## Documented, Not Scoped

- **`voiceProvider`.** Present in avatar-tester, absent from BEAI. Not added
  here: a knob BEAI never sends, introduced only to hang a hint on, is invented
  surface.
