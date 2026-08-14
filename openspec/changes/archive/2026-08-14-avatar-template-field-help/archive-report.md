# Archive report: Field Help on the Avatar Template Form

**Archived** 2026-08-14.

## Verification

| Scenario | Test |
|---|---|
| Each rendered field carries its hint | `avatar-template-form.spec` — every hinted fixture field |
| A field without a hint still works | `avatar-template-form.spec` — control present, no stray key |

28 of 28 BEAI fields received a hint; nothing was left unexplained. Locale
parity between it and en verified after the port.

## Copy ported, not rewritten

The hints come verbatim from `quint-avatar-tester`, which already carried
reviewed prose for every field in both locales. Rewriting them would have been
re-deciding something already decided, and the existing text does the thing that
matters: it says where to FIND a value, not merely what it is called.

## Deliberately not added

`voiceProvider` exists in avatar-tester and not in BEAI. It was not introduced:
a knob BEAI never sends, added only so a hint has somewhere to live, is invented
surface. It stays out until BEAI actually uses it — which is also why an export
carrying that key is still refused on import.
