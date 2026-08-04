# Visitor Mailer Readme

Emails visitors when they are invited (including a QR code for check-in), notifies
hosts when visitors check in, and notifies a previous host when a booking's host is
reassigned. Also handles induction and change notifications.

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
  # When true, attendees sharing the host's email domain are treated as staff
  # rather than visitors and are not emailed
  skip_internal_domain_email: false
```

## Change notifications

When a visit's date, time or location changes, the visitors already on it are sent the
`booking_changed` or `event_changed` template. A visitor added by the same edit is left
out — the invitation they are receiving already carries the new details, and they never
saw the old ones.

One edit usually produces several signals, so change emails are held briefly and
combined into a single email describing the net change.

```yaml
  # Combine change emails sent within this many seconds; 0 disables.
  change_debounce: 15
```

The email goes out a few seconds after the window closes. Anything still waiting is
sent immediately if the driver restarts, so a notification is never dropped.

Setting this to `0` emails on every signal, which can mean duplicate and contradictory
notifications, and can also notify visitors added by the edit.

## Excluding staff attendees

The front end might mark any attendee as an expected visitor, so staff invited to a
meeting can receive visitor invites and QR codes.

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

The `booking_changed` and `event_changed` templates receive `guest_jwt` and `kiosk_url`
fields and the same inline `qr.png` attachment as an invitation, because a move
invalidates the kiosk link issued with the original invite.

Reference the attachment the same way the invite template does, or set
`disable_qr_code: true` to leave it off. An unreferenced attachment may still show up
in some mail clients.

## Reply-To

Visitor emails set a `Reply-To` header so replies reach the visitor's host rather than
the no-reply sender address (for the "original host changed" notification it is the new
host). This requires no configuration.

It can be overridden per-template (a `reply_to` field on the template metadata),
tenant-wide (the `reply_to` setting on the Template Mailer), or for all mail (the
`reply_to` setting on the SMTP Mailer). See the Template Mailer readme for the full
precedence cascade.
