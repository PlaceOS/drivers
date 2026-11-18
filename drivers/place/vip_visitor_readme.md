# VIP visitor automation integration

This workflow handles standalone Staff API bookings with `booking_type: "vip-visitor"`.
Bookings must include the configured building zone ID. Cancelled, deleted, rejected
and child bookings (a top-level or extension-data `parent_id`) are excluded. Create
individual standalone bookings for multiple VIP visitors.

Compile `drivers/place/vip_visitor_automation.cr` as **VIP Visitor Automation** and
add a `VIPVisitorAutomation` module to the building's system. Add `StaffAPI_1`,
`Calendar_1`, Template Mailer as `Mailer_1`, and its downstream SMTP mailer as
`Mailer_2`. Configure one workflow instance per building.

Planner orchestration is part of `VIPVisitorAutomation` and calls the existing
Calendar driver's `create_plan`, `create_bucket` and `create_task` methods. There is
no separate `VIPVisitorPlanner` driver or module. An earlier
`vip_visitor_planner.cr` source helper could not compile independently; removing
that file does not remove any obsolete driver record already registered in
Backoffice. Remove such a record after checking that no system modules reference it.

## Module settings

Configure deployment-specific values on the VIPVisitorAutomation module.

| Setting | Value and purpose |
| --- | --- |
| `building_id` | Required PlaceOS building **zone ID**, such as `zone-building`; not a system ID. Bookings outside this zone are ignored. |
| `planner_group_id` | Optional default Microsoft 365 group object ID. A booking's `extension_data.planner_group_id` takes precedence. At least one is required when creating a plan. |
| `confirmation_url` | HTTPS URL of the external form the assistant must complete; see the confirmation section below. |
| `domain_uri` | PlaceOS HTTPS authority URL; its hostname becomes the invitation JWT audience. |
| `jwt_private_key` | Signing key trusted by the deployment. Defaults to the key exposed by the framework; only override with the matching deployment key. |
| `handler_emails` | Array of completed-form email recipients. Required when sending the confirmation email. Template To/CC/BCC can override or extend recipients. |
| `timezone` | IANA timezone used in emails and restaurant reservation task titles, e.g. `Asia/Dubai` or `Europe/London`. Default: `Asia/Dubai`. |
| `planner_task_assignments` | Task keys mapped to arrays of Microsoft user object IDs; omitted tasks remain unassigned. See below. |
| `workflow_state` | Automatically maintained progress, including destination, plan, bucket and task IDs. Do not populate manually or clear to retry; clearing progress can repeat external operations. |

Example:

```yaml
building_id: zone-building
planner_group_id: microsoft-365-group-object-id
timezone: Europe/London
domain_uri: https://placeos.example.com
confirmation_url: https://placeos.example.com/enrolment/#/
handler_emails:
  - vip-handlers@example.com
planner_task_assignments:
  meet_greet:
    - microsoft-user-object-id
```

There is no configurable confirmation field: acceptance is the boolean
`extension_data.vip_confirmed: true`. The driver has no settings for location,
map links, parking or valet wording, arrival/departure enablement, or notification
recipient lists. Those presentation and notification choices belong to templates.

## Planner destination and assignments

For a booking-specific destination, the internal booking request should persist:

```json
{
  "extension_data": {
    "planner_group_id": "microsoft-365-group-object-id"
  }
}
```

A nonblank booking value overrides the module default. After plan creation
succeeds, the resolved destination is saved as `workflow_state.planner_group_id`
alongside the plan ID. Once a plan exists, retries keep that destination even if
the booking or module setting changes. If creation fails before a plan ID is
returned, you can correct the booking or module group and retry. The assistant
submission method preserves this internal booking field and does not accept a
replacement destination.

The group must already exist. Each confirmed visit gets a new plan with **To Do**,
**In Progress**, and **Done** buckets. Selected tasks start in To Do. This workflow
does not create a Team, channel, Microsoft 365 group, or group membership.

`planner_task_assignments` chooses who receives each type of task. For example:

```yaml
planner_task_assignments:
  meet_greet:
    - reception-user-object-id
    - protocol-officer-user-object-id
  welcome_beverage:
    - catering-user-object-id
  driver:
    - transport-user-object-id
```

These values are Microsoft user object IDs, not email addresses, PlaceOS user IDs
or AD group IDs. The array can contain more than one user. It is passed to
Calendar's `assigned_to_user_ids` when that task is created; it does not create the
task unless the booking selected the corresponding option.

| Task key | Task |
| --- | --- |
| `meet_greet` | Internal or airport meet and greet |
| `tour` | Walkthrough/guided tour |
| `welcome_beverage` | Selected beverage, including custom notes |
| `gift` | Giveaway gift |
| `photographer` | Photographer |
| `restaurant_reservation` | Restaurant name, address and reservation time |
| `driver` | In-house or third-party driver |
| `welcome_screen` | Welcome screen |
| `presentation` | Presentation |

Omit a key, or leave the entire setting as `{}`, to leave those tasks unassigned.
Changing assignments later does not reassign already-created tasks. Tasks are
created from the confirmed booking's details; later booking edits do not rewrite a
completed plan. No template plan is cloned. Configure Calendar with the necessary
Planner access and tenant consent for the intended groups and users.

## Templates and zone names

Create these Template Mailer triggers:

| Trigger | Default recipient and behaviour |
| --- | --- |
| `vip_visitor.invitation` | The booking's `extension_data.vip_assistant_email`; includes the form link and QR image. |
| `vip_visitor.confirmed` | `handler_emails`; includes submitted form fields. |
| `vip_visitor.arrived` | Booking host (`user_email`); skipped when this template is absent. |
| `vip_visitor.departed` | Booking host (`user_email`); skipped when this template is absent. |

Use template **To** to replace the default recipient and **CC/BCC** to add recipients.
For arrival/departure emails, the presence of the corresponding template enables
sending. No notification settings need to be switched on. An absent template is
skipped without marking that notification as sent; adding it later allows a
subsequent event or manual invocation to send it. Notifications are sent once per
booking and action after a successful send.

`building_name` is the configured building zone's `display_name`, falling back to
its `name`. `level_name` comes from the booking zone tagged `level`, with the same
fallback; it is empty when the booking contains no level zone. Template selection
uses Template Mailer's configured organisation and building zones; the notification
presence check uses those same zones.

Concierge users put map links and parking/valet instructions directly into the
email template. For example:

```text
VIP visit: %{booking_title}
%{event_date}, %{event_time} – %{event_end_time}
Location: %{building_name}, %{level_name}
Map: [insert the desired map link here]
Parking: [write the current visitor parking instructions here]
Valet: [write the current valet instructions here]
Please complete the visit details: %{confirmation_url}
```

The invitation includes an inline QR image; an HTML template can use
`<img src="%{qr_code}" alt="Visitor QR code">`.

The confirmed template receives the actual form field names listed below, plus
compatibility aliases from the original scope document. `%{submitted_details}`
contains the booking extension data as JSON. Template Mailer replaces placeholders
literally, so use a plain-text completed-form body for submitted free text.
`template_fields` supplies available field definitions to Template Mailer; it does
not send an email or process a booking.

## Confirmation URL and form submission

`confirmation_url` is the address of the web form the external assistant opens.
It is not the submission API URL. For example, configuring
`https://placeos.example.com/enrolment/#/` produces an invitation link shaped like:

```text
https://placeos.example.com/enrolment/#/?uid=<signed-guest-JWT>
```

The driver adds `uid` to the URL fragment's query parameters. The token identifies
the visitor and exact booking (`u.b`), includes the permitted resource IDs (`u.r`),
and expires at the booking end time. The app reads the token to identify the visit.
Setting this URL does not deploy the form or implement its backend endpoint.

For testing from Backoffice, execute **`submit_confirmation`** with the numeric
booking ID and the same fields the AECB enrolment form submits:

```json
{
  "booking_id": 12345,
  "vip_title": "Dr",
  "vip_full_name": "Example Visitor",
  "vip_contact_number": "+971500000001",
  "assistant_name": "Example Assistant",
  "assistant_contact_number": "+971500000002",
  "protocol_officer_name": "Example Officer",
  "protocol_officer_contact_number": "+971500000003",
  "vehicle_plate_number": "12345",
  "vehicle_plate_type": "Private",
  "beverage_preference": "custom",
  "beverage_notes": "Tea, no sugar"
}
```

Replace `12345` with a real standalone VIP booking ID. Provide the named strings;
unused optional form details can be empty strings. `vip_full_name` must not be
blank. Beverage preference accepts `none`, `standard`, or `custom` and is normalised
to lower case. `beverage_notes` defaults to an empty string and is cleared unless
the preference is `custom`. Submitted custom notes, including an empty string,
replace the organiser's original beverage notes.

This method merges just these fields and the fixed `vip_confirmed: true` marker
into the booking via Staff API. It preserves other options, assistant email, and
Planner destination. It saves with `signal_changes: false`, then directly runs the
workflow: completed-form email followed by Planner provisioning. **This performs
real booking updates, emails and Planner operations.** It is an administrator-only
method, not a dry run or an external guest endpoint. Use `preview_booking` for
inspection without those effects.

The UI inspected on `origin/custom/ACB012M` currently saves these form fields but
sets no acceptance marker. Its separate check-in action does not constitute form
acceptance. Production form integration must save the fixed marker when submitting.

### External integration still required

Before connecting the external form, implement a scoped backend endpoint for
reading/submitting the permitted booking details and update the form to use it.
The endpoint must verify the invitation token's signature, expiry, audience,
tenant and booking binding. It must permit only the confirmation fields and save
`vip_confirmed: true` with them, then trigger processing through a booking-change
signal or a trusted server-side workflow invocation.

The current `guest`/`metadata` JWT cannot read or PATCH the general
`/api/staff/v1/bookings/:id` routes in the inspected backend. Those routes require
public API scope and writes also require ownership or zone-manager permission.
A booking claim alone does not grant this access. Do not solve this by granting
the external assistant a broadly privileged staff token. The Backoffice submission
method lets an administrator test the completed-form workflow while this external
integration remains outstanding.

## Executable methods and a Backoffice test sequence

All methods below require administrator access. Individual stage methods share
validation and saved progress with automatic processing.

| Method | Behaviour |
| --- | --- |
| `list_bookings(period_start, period_end)` | Lists eligible VIP bookings in the configured building over an explicit Unix-seconds time window. Use a result's numeric `id`. |
| `get_booking(booking_id)` | Fetches the booking and rejects an ineligible booking. |
| `workflow_status(booking_id)` | Returns saved progress; an unprocessed booking has an empty object. No processing occurs. |
| `preview_booking(booking_id)` | Returns confirmation status, resolved Planner group, proposed task titles, template arguments and current progress. Creates no token, email, booking update or Planner resource. |
| `send_invitation(booking_id, force = false)` | Sends only the invitation for an unconfirmed booking. Skips an unchanged invitation unless `force` is true. |
| `submit_confirmation(...)` | Persists the form fields and acceptance marker, then runs confirmation email and Planner stages. See the complete example above. |
| `send_confirmation(booking_id)` | Sends only the completed-form email for an already-confirmed booking; skips an already-sent email. |
| `provision_plan(booking_id)` | Creates/resumes only the plan, buckets and selected tasks for an already-confirmed booking. Returns the plan ID. |
| `send_arrival_notification(booking_id)` | Sends only the arrival email if a template exists and it has not already been sent. Does not check the visitor in. |
| `send_departure_notification(booking_id)` | Sends only the departure email if a template exists and it has not already been sent. Does not check the visitor out. |
| `process_booking(booking_id, action = "changed")` | Runs applicable stages from the persisted booking and resumes failures. `arrived`/`departed` also attempts the corresponding notification; an action alone does not change booking state. |

A practical test is: list bookings, inspect one with `get_booking` and
`preview_booking`, send its invitation, then execute `submit_confirmation` and
inspect `workflow_status`. Use test recipients and an intended test Planner group.
To test confirmation email and Planner provisioning separately, start with an
already-confirmed booking that has not been processed and invoke each stage method.

Repeated unchanged events skip completed operations. Before acceptance, changing
the visit time, title, visitor email or assistant name/email sends a replacement
invitation. `workflow_state` is checkpointed through the framework's asynchronous
`define_setting` mechanism. There is a crash window between a successful external
operation and its saved checkpoint; this is not a transactional exactly-once
promise across services. Retry with `process_booking` or the failed stage rather
than deleting the saved state.

## Automatic events

On load, the module subscribes to `staff/booking/changed`,
`staff/guest/attending`, and `staff/guest/checkin`. It fetches the booking, checks
eligibility, and determines acceptance from `vip_confirmed`. It does not perform a
startup scan or scheduled retry of missed events.

| Event/action | Meaning |
| --- | --- |
| Booking `create` | New booking; send the invitation unless already confirmed. |
| Booking `metadata_changed` or `changed` | Fetch current details and run applicable stages. |
| Booking `extdata_changed` | Extension-data PATCH with `signal_changes=true`. |
| Booking `checked_in` | `checked_in: true` means arrival; false means departure. |
| Guest `attending` | An attendee was added, including during creation; this alone is neither acceptance nor arrival. |
| Guest `checkin` | `checkin: true/false` means arrival/departure. |

For a form endpoint that writes extension data directly, request
`signal_changes=true` so the update triggers the automation. The driver submission
method deliberately uses false because it invokes processing itself.

## Field compatibility and deployment

The AECB form uses `vip_contact_number`, `assistant_name`,
`assistant_contact_number`, `protocol_officer_contact_number`,
`beverage_preference` and `beverage_notes`. For existing templates, the driver also
provides the original document aliases `vip_mobile_number`, `vip_assistant_name`,
`vip_assistant_mobile_number`, `protocol_officer_mobile_number`,
`welcome_beverage` and `welcome_beverage_notes`, preferring submitted values.
Planner selection accepts `tour` or the booking form's `walkthrough`, and `driver`
values `In-house`/`Third Party` or `in_house`/`third_party`.

When ordinary Visitor Mailer also handles the building, its companion
`exclude_booking_types` support must be installed and configured with
`["vip-visitor"]` to avoid duplicate ordinary visitor emails. That companion change
is not part of this VIP driver change.

The wider journey's reminders, WhatsApp messages, catering, access control,
welcome screens and thank-you messages remain separate automations. Validate the
external form endpoint, invitation, submitted-details email, selected tasks,
retries and template-controlled arrival/departure emails before deployment.
The harness uses mocked services and does not validate live Microsoft access or
external form authentication.

## Validation

The driver and expanded spec compile and pass the PlaceOS harness: **1 tested,
0 failures, 0 timeouts**. Coverage includes independent executable stages,
read-only inspection, form persistence and validation, template-controlled
notifications, zone names, Planner destination overrides, retries, duplicate
suppression, and cleared beverage notes. Formatting and diff checks also pass.
