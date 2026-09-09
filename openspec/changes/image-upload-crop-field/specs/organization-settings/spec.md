# Delta for Organization Settings

## MODIFIED Requirements

### Requirement: The organization logo is chosen through a framed, previewed upload field

The Appearance section MUST present the logo as a single upload field carrying an explicit
call to action, the required shape, and the accepted formats — not a bare file input.

Choosing a file MUST open a crop dialog before anything is queued for upload. The operator
MUST be able to pan and zoom within a fixed-ratio frame, and MUST confirm or cancel. Only a
confirmed crop becomes the file that is uploaded; cancelling MUST leave the previously
stored logo untouched.

The logo frame MUST be square (`1:1`) and MUST fit the whole source image inside that
square at minimum zoom rather than filling it. A wide logotype MUST NOT lose its ends to a
default framing.

After a confirmed crop the field MUST show the cropped result immediately, before any
network request, so that choosing a file always produces a visible change.

The client-side format filter on the file picker remains a convenience only. The server's
magic-byte verification, byte cap and dimension ceiling MUST be unchanged by this
requirement.

#### Scenario: Choosing a file opens the crop dialog

- GIVEN an admin in Settings → Appearance
- WHEN they choose an image file
- THEN a crop dialog opens showing that image inside a square frame
- AND nothing has been uploaded

#### Scenario: Cancelling the crop keeps the stored logo

- GIVEN an organization with a stored logo, and an open crop dialog over a newly chosen file
- WHEN the operator cancels
- THEN no upload is made and the stored logo is still shown

#### Scenario: A confirmed crop previews before it is saved

- GIVEN an open crop dialog
- WHEN the operator confirms
- THEN the field shows the cropped image immediately
- AND the file is uploaded when the form is submitted

#### Scenario: A wide logotype is padded, never trimmed

- GIVEN a source image far wider than it is tall
- WHEN the crop dialog opens at minimum zoom
- THEN the whole image is visible inside the square frame, padded rather than cropped

### Requirement: `logo_url` is resolvable from every app that renders it

Every API response carrying a logo URL MUST return an absolute URL. The backoffice, the
candidate frontend and email clients are all separate origins from the API, so a
root-relative path resolves against the wrong host and yields a broken image in all three.

This applies to the organization settings resource and to the participant resource's
`branding.logo_url`.

The field's type is unchanged: a nullable string, `null` when no logo is configured.

#### Scenario: The settings resource returns an absolute URL

- GIVEN an organization with a stored logo on the local disk
- WHEN the backoffice reads the organization
- THEN `logo_url` begins with the configured application URL and is fetchable from another origin

#### Scenario: No logo still means null

- GIVEN an organization with no logo configured
- WHEN the resource is serialised
- THEN `logo_url` is null, not an empty or partial URL
