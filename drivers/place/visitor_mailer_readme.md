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
```

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
