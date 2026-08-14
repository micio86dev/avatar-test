# Proposal: Field Help on the Avatar Template Form

## Intent

The avatar template form asks an operator for 29 provider settings — `avatarId`,
`voiceStability`, `interruptibility`, `turnTakingPatience` — and explains none
of them. It renders a label and an input, and expects the operator to already
know what a HeyGen voice stability of 0.5 does.

They do not, and the product never tells them. The result is a form filled by
copying whatever was there before, or by guessing.

## The copy already exists

`quint-avatar-tester` carries a written hint for **every one of the 29 fields**,
in Italian and English, e.g.:

> *L'identificativo dell'avatar HeyGen. Lo trovi nella dashboard HeyGen, aprendo
> l'avatar: è il codice mostrato sotto il suo nome (o nell'URL della pagina).*

That is the sentence an operator needs, and it says where to FIND the value, not
merely what it is called. It is already reviewed prose in both locales.

## Scope

- `FieldSpec` gains a hint key alongside its label key.
- `ProviderFieldSpecs` populates it for every field of both providers.
- `AvatarTemplateForm` renders it under each control.
- The 29 hints are ported into `i18n/locales/{it,en}.json`.

## Non-goals

- **No new fields, no changed validation.** This is explanatory copy on a form
  that already works.
- **`voiceProvider` is not added.** avatar-tester has it and BEAI does not;
  adding a knob BEAI never sends, only to have somewhere to hang a hint, would
  be inventing surface. It stays out until BEAI actually uses it.
