# VIP visitor automation integration

This workflow is for standalone Staff API bookings with `booking_type: "vip-visitor"`.
Bookings with a top-level `parent_id` or an `extension_data.parent_id` are excluded.
This also excludes children of group bookings; create individual standalone VIP
bookings for this implementation. Multiple-visitor group support is not included.
Planner operations use the existing Calendar driver, which provides `create_plan`,
`create_bucket`, and `create_task`. A separate Planner service driver is not required.
Creating a Planner plan in a configured Microsoft 365 group does not create a new
Microsoft Teams team or channel. Provision the intended group/Team separately.

The `exclude_booking_types` option described below belongs to a companion
VisitorMailer change. It is not included in this new-driver-only change; ensure
that support is present before running both mail workflows for VIP bookings.

## Configuration

Add `VIPVisitorAutomation`, `StaffAPI_1`, and `Calendar_1` to the building's system.
Configure Template Mailer as `Mailer_1` and its downstream SMTP mailer as
`Mailer_2`. Configure one workflow instance per building.

| Setting | Purpose |
| --- | --- |
| `building_id` | Required building zone ID; bookings outside it are ignored |
| `planner_group_id` | Existing Microsoft 365 group that owns the plans |
| `confirmation_url` | HTTPS address of the compatible confirmation application |
| `domain_uri` | PlaceOS authority URL used as JWT audience |
| `jwt_private_key` | Signing key trusted by the PlaceOS backend |
| `confirmation_field` | Boolean extension-data submission marker; defaults to `vip_confirmed` |
| `handler_emails` | Recipients of the completed form email |
| `timezone` | Email time zone, default `Asia/Dubai` |
| `location`, `google_maps_url`, `parking_details`, `valet_details` | Invitation template details |
| `notify_arrival_departure` | Enable optional arrival/departure emails; default false |
| `notification_emails` | Arrival/departure recipients, e.g. office/building managers |
| `planner_task_assignments` | Task-key to Microsoft user-ID array; unspecified tasks remain unassigned |

Configure Template Mailer templates `vip_visitor.invitation`,
`vip_visitor.confirmed`, and, when enabled, `vip_visitor.arrived` and
`vip_visitor.departed`. Arguments include extension-data fields, `booking_id`,
`booking_title`, `booking_user_name`, `booking_user_email`, `booking_booking_start`,
`booking_booking_end`, `event_date`, `event_time`, `event_end_time`, and configured location details.
The invitation also provides `confirmation_url`, `visitor_email`, and an inline
QR image referenced through `qr_code`.

`submitted_details` contains the extension data as JSON. Template Mailer performs
literal placeholder replacement, so use a plain-text completed-form template for
untrusted form fields rather than inserting raw values into HTML. Restrict template
recipients to the VIP handlers; template-level `to`, `cc`, and `bcc` settings can
override or extend the recipients configured on this driver.

Before acceptance, changes to the booking time, title, visitor email, or assistant name/email send a replacement invitation. Repeated unchanged events do not resend.

The confirmed template receives the submitted extension-data fields. Include all
requested form fields in that template to produce the completed-form email.

The confirmation endpoint must save `extension_data.vip_confirmed: true` (or the
configured field) with the submitted details. An ordinary booking edit without
that marker must not create a plan.

Workflow progress is checkpointed in the driver setting `workflow_state` after
successful downstream operations using the framework’s asynchronous `define_setting` mechanism. Keep this setting across restarts. An operator
can retry a failed workflow with administrator-only `process_booking(booking_id)`.
There is a crash window between a successful external operation and its saved
checkpoint, so this is not a transactional exactly-once guarantee across services.

Example settings (replace placeholders; the confirmation endpoint must be ready
before enabling live invitations):

```yaml
building_id: zone-aecb-building
planner_group_id: microsoft-365-group-object-id
timezone: Asia/Dubai
domain_uri: https://placeos.example.com
confirmation_url: https://placeos.example.com/enrolment/#/
confirmation_field: vip_confirmed
handler_emails:
  - vip-handlers@example.com
location: Rolex Tower
google_maps_url: https://maps.google.com/?q=Rolex+Tower+Dubai
parking_details: Use the visitor parking entrance.
valet_details: Contact reception on arrival.
notify_arrival_departure: false
```

Use the platform's configured signing key or set `jwt_private_key` securely; never
place a private key in a committed example configuration. The driver adds the JWT
as the fragment query parameter `uid` to the confirmation URL.

If the ordinary Visitor Mailer is also active in this building, set this on that
driver to prevent normal invitation and notification emails for VIP bookings:

```yaml
exclude_booking_types:
  - vip-visitor
```

The exclusion defaults to an empty list and covers booking guest events, booking
changes, previous-host notifications, and booking reminders. Calendar-event
visitors remain unaffected.

## Deployment checks

- Implement and test the restricted confirmation endpoint and the form's explicit
  acceptance marker; the existing generic booking PATCH route is insufficient.
- Configure the existing Microsoft 365 group, Calendar's Planner access, signing
  key and authority domain; a new Teams team/channel is not created.
- Configure invitation and completed-form templates, QR image, location, map,
  parking/valet information, and handler recipients. Check template overrides.
- Exclude VIP bookings from the ordinary Visitor Mailer when both drivers run.
- Verify invitation, submission email, selected tasks, retry after failure, and
  duplicate-event suppression in staging with test recipients.
- Enable optional arrival/departure notifications only after confirming recipients.

These are deployment instructions; development and tests do not send live emails
or create live Microsoft Planner resources.

## Staff API events

The locally inspected Staff API publishes `staff/booking/changed` for booking
creation and updates. The payload includes `id`, `booking_type`, `zones`,
`booking_start`, `booking_end`, `user_email`, `booked_by_email`, and `extension_data`.

| Action | Meaning |
| --- | --- |
| `create` | New booking |
| `metadata_changed` | Ordinary booking PATCH without a time/resource change |
| `changed` | Booking PATCH that resets booking state |
| `extdata_changed` | PATCH `/bookings/:id/ext_data?signal_changes=true` |
| `checked_in` | Check-in **or check-out**; inspect `checked_in` |

The extension-data-only endpoint defaults `signal_changes` to false. Use true
when the form submission needs to trigger automation.

`staff/guest/attending` is emitted when an attendee is added, including initial
booking creation. It is not a confirmation-form-submitted event, and does not
contain `booking_type` or extension data. The sequence diagram's claim that a
metadata PATCH produces that event does not match the inspected implementation.

`staff/guest/checkin` carries `booking_id` and `checkin: true/false`. Arrival and
departure must remain separate from acceptance of an invitation.

## External confirmation app integration gap

The AECB UI implementation inspected in `aecb-catering-host-backport` has the
enrolment route `/enrolment/#/?uid=<JWT>`. Its token parser expects `u.r` and selects
VIP mode using `u.b` or a top-level `booking_id`. Its confirmation form PATCHes the
booking extension data, but currently writes no explicit acceptance marker.
The separate check-in button invokes the booking check-in endpoint.

Before connecting that external form, implement a scoped backend confirmation
endpoint and update the form to use it. The endpoint must verify the token's
signature, expiry, audience, tenant and exact booking binding; permit only the
confirmation fields; and persist an explicit submission marker with the form
data before publishing the booking-changed event. Treat that marker as acceptance,
not the presence of optional phone/name/car fields or an arbitrary booking edit.

The existing guest JWT scopes (`guest`, `metadata`) cannot read or PATCH the
general `/api/staff/v1/bookings/:id` endpoints in the inspected backend. Those
endpoints require public API scope and writes additionally require the booking
owner or a zone manager. Adding a booking claim to a JWT does not itself grant
access. Do not issue a broadly privileged staff token to the external assistant.

The guest profile PATCH endpoint updates the guest record, not booking metadata.
Guest catering endpoints support a limited beverage selection, not arbitrary VIP
form submission. Neither is a substitute for the required confirmation endpoint.

## Field compatibility

The implementation document and the existing AECB UI use some different keys:

| Document key/value | Existing AECB UI key/value |
| --- | --- |
| `tour` | `walkthrough` |
| `vip_mobile_number` | `vip_contact_number` |
| `vip_assistant_name` (submitted) | `assistant_name` |
| `vip_assistant_mobile_number` | `assistant_contact_number` |
| `protocol_officer_mobile_number` | `protocol_officer_contact_number` |
| `welcome_beverage` (submitted) | `beverage_preference` |
| Beverage notes | `beverage_notes` (submitted), `welcome_beverage_custom` (booked) |
| `In-house`, `Third Party` | `in_house`, `third_party` |

The UI uses lower-case `none`, `standard`, `custom` beverage values. Prefer the
submitted beverage choice over the original booking choice when both are present.
Keep all submitted fields available to the handler email template.

## Scope of source documents

Both local PDFs were read, and the journey diagram was rendered and inspected.
The wider journey diagram includes reminders, WhatsApp messages, catering,
access control, welcome screens, and thank-you messages. Those are separate
automations from the core invitation, submission email, and Planner workflow.
The diagram's phrase “Space on Teams” does not add a Teams-creation operation to
the Calendar driver's Planner methods.

## Planner permissions

The Calendar connection needs Planner write permissions. Microsoft documents
`Tasks.ReadWrite` for delegated work/school accounts and `Tasks.ReadWrite.All`
for application access for [creating plans](https://learn.microsoft.com/en-us/graph/api/planner-post-plans?view=graph-rest-1.0).
Confirm tenant consent and access to the configured group before deployment.
Tasks are created from the confirmed booking snapshot; later edits do not rewrite
an already completed Planner workflow. No existing template plan is cloned:
the three buckets and conditional tasks are defined by this driver.

## Minimal template bodies

For `vip_visitor.invitation`, a plain-text starting point is:

```text
VIP visit: %{booking_title}
%{event_date}, %{event_time} – %{event_end_time}
Location: %{location}
Google Maps: %{google_maps_url}
Parking: %{parking_details}
Valet: %{valet_details}
Please complete the visit details: %{confirmation_url}
```

In the HTML invitation, reference the attached QR image with
`<img src="%{qr_code}" alt="Visitor QR code">`.
For `vip_visitor.confirmed`, include `%{submitted_details}` in the plain-text body
to return every submitted field to the handlers. These are template configuration
examples; the driver does not create or send tenant templates during installation.

## Validation

The VIP automation driver/spec compiled and passed the driver harness, covering
conditional tasks, submitted field aliases, invitation refresh and duplicate
suppression, explicit acceptance, partial-failure resume, and lifecycle events.
The focused VisitorMailer exclusion regression passed with the complete spec
restored afterwards. Formatting and diff checks passed.

The complete existing VisitorMailer suite did not pass in this environment:
separate runs failed in existing system-lookup retry and debounce timing
assertions before reaching the new exclusion checks. No production mail or
Microsoft Graph resources were used in these tests.
