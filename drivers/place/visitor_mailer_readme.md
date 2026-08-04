# Visitor Mailer Readme

Emails visitors when they are invited (including a QR code for check-in), notifies
hosts when visitors check in, and notifies a previous host when a booking's host is
reassigned. Also handles induction and booking-changed notifications.

## Requirements

Requires the following drivers in the system:

* StaffAPI - for guest/booking details and host names
* Mailer - for sending emails (and where the templates are configured)
* Calendar - for resolving host names (depending on configuration)

## Configuration

```yaml
  timezone:           "GMT"
  date_format:        "%A, %-d %B"
  time_format:        "%l:%M%p"
  booking_space_name: "Client Floor"
  send_reminders:     "0 7 * * *"
  reminder_template:  "visitor"
  event_template:     "event"
  # When true, the host is not sent visitor-targeted emails
  skip_host_email:    true
  # When true, attendees sharing the host's email domain are treated as
  # colleagues rather than visitors and are not emailed
  skip_internal_domain_email: false
```

## Debouncing change notifications

A single edit is rarely a single signal: Office365 emits a burst of
`staff/event/changed` updates (the organizer copy, then each room mailbox catching
up), which can briefly flip-flop between the old and new values. Sending an email
per signal spams visitors with contradictory notifications.

`event_change_debounce` and `booking_change_debounce` (seconds, default `15`) buffer
the burst for one visit and send a single email describing the net change once the
window closes. Set one to `0` to email on every signal for that kind of change.

```yaml
  # Combine duplicate change emails sent within this many seconds; 0 disables.
  event_change_debounce:   15
  booking_change_debounce: 15
```

Buffered changes are swept on a timer rather than each having its own, so the actual
delay is the configured debounce plus up to one sweep interval (at most 5s). Anything
still buffered is emailed immediately when the driver is unloaded, or when every
debounce is turned off, so a restart never silently drops a pending notification.

Event signals are grouped by event instance (its ical uid), not by room, so an edit
that moves the meeting *and* changes the time sends one email describing both rather
than one per room. A move between buildings is handled by two separate mailer modules
and so still sends an email each. Booking signals are grouped by booking id.

The booking debounce also buys the window needed to recognise a visitor added by the
same edit, so setting it to `0` will re-notify new visitors — see below.

## New visitors are not told the visit changed

A visitor added while the details are being changed does not need a change
notification: the invitation they are receiving already carries the new date, time and
location, and they never saw the old ones. Being told their visit "changed" before
they have registered being invited to it at all is worse than confusing — QA saw the
change notification arrive alongside, and sometimes in place of, the invite.

The staff API announces attendance (`staff/guest/attending`) only for attendees that
were not already attending, which makes it an exact statement of "this visitor is
new". Each such announcement is remembered for the debounce window plus a minute, and
those visitors are left out of any change notification for the same visit in that
time. Recipients are matched on visitor, host and the new start time rather than on
the booking id, because a change notification names the *parent* booking while the
invitation names the visitor's own child booking — and for an event-linked visitor
booking the two ids do not correspond at all.

This works regardless of where the edit came from (workplace, concierge, Outlook or
another driver), as it depends only on the signals rather than on the request that
caused them. The invitation is remembered even when the invite email itself is
suppressed by `disable_event_visitors` or `skip_event_linked_booking_email`, since in
both cases the visitor was still invited, just through the other template.

## Colleagues are not visitors

Front ends tend to mark every attendee of a meeting as an expected visitor, so staff
invited to a meeting are announced by the staff API exactly like external guests and
would receive visitor invites and QR codes.

Two settings filter them out:

```yaml
  # skip anyone whose email domain matches the host's
  skip_internal_domain_email: true
  # or list the domains explicitly
  host_domain_filter: ["your-company.com"]
```

Both apply to invitations, check-in and induction notifications, and change
notifications. Emails aimed at the host (`notify_checkin`, `notify_original_host`) are
unaffected — they are filtered on the *attendee's* domain, not the recipient's.

## QR code and kiosk link on change notifications

The `booking_changed` and `event_changed` templates receive `guest_jwt` and
`kiosk_url` fields and the same inline `qr.png` attachment as an invitation, because
a move invalidates the kiosk link issued with the original invite — its token is
scoped to the room the meeting has just left, and no fresh invitation is sent.

Reference the attachment from the template the same way the invite template does, or
set `disable_qr_code: true` to leave it off. Until a template uses them the fields are
simply unused, though an unreferenced attachment may still show up in some mail
clients.

## Reply-To

Visitor emails set a `Reply-To` header so replies reach a useful person rather than
the no-reply sender address. By default the reply-to is the visitor's **host**
(for the "original host changed" notification it is the new host). This means a
visitor replying to their invite reaches the person hosting them. This requires no
configuration.

This default can be overridden per-template (a `reply_to` field on the template
metadata), tenant-wide (the `reply_to` setting on the Template Mailer), or for all
mail (the `reply_to` setting on the SMTP Mailer). See the Template Mailer readme
for the full precedence cascade.
