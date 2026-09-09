# Delta for User Self-Service

## MODIFIED Requirements

### Requirement: The profile photo is framed before it is uploaded

The profile photo control MUST use the same upload field as every other image upload in
the backoffice. Choosing a file MUST open the crop dialog rather than uploading whatever
rectangle was selected.

The photo frame MUST be square (`1:1`) and MUST fill that square at minimum zoom — a face
photo has no edges worth preserving, and padding inside a circular avatar mask reads as a
rendering fault. The mask shown in the dialog MUST be circular, matching how the avatar is
actually displayed, while the exported file stays a square image.

Upload MUST happen on confirmation of the crop, preserving the existing immediate-save
behaviour of this control. Removing a stored photo MUST remain behind an explicit
confirmation.

#### Scenario: Choosing a photo opens the circular crop dialog

- GIVEN a signed-in user on their profile page
- WHEN they choose an image file
- THEN a crop dialog opens with a circular mask over a square frame
- AND no upload has been made

#### Scenario: Confirming the crop uploads the cropped image

- GIVEN an open crop dialog on the profile photo
- WHEN the user confirms
- THEN the cropped image is uploaded and shown as the avatar

#### Scenario: Cancelling leaves the current avatar in place

- GIVEN a user with an existing profile photo, and an open crop dialog
- WHEN the user cancels
- THEN no request is made and the existing avatar is unchanged

#### Scenario: Removal still requires confirmation

- GIVEN a user with a stored profile photo
- WHEN they choose to remove it
- THEN a confirmation is required before the photo is deleted

### Requirement: The crop dialog is operable without a pointer

The crop dialog MUST be fully operable from the keyboard. The frame MUST be focusable and
MUST respond to arrow keys for panning and to `+` / `-` for zoom, and the zoom control MUST
be a labelled native range input.

A crop tool reachable only by dragging excludes keyboard and assistive-technology users
from a step that is now mandatory to upload any image at all.

#### Scenario: Panning and zooming from the keyboard

- GIVEN an open crop dialog with the frame focused
- WHEN the user presses an arrow key
- THEN the image pans, staying within its clamped bounds

#### Scenario: The zoom control is labelled

- GIVEN an open crop dialog
- WHEN the zoom control is inspected
- THEN it is a range input with an accessible name
