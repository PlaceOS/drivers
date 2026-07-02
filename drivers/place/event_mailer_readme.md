# Event Mailer Readme

Subscribes to calendar events surfaced by a Bookings module and emails the event
organiser (e.g. a welcome email when their event is occurring today). Optionally
provisions network credentials for the organiser.

## Requirements

Requires the following drivers in the system:

* StaffAPI - for listing systems in the target zones and storing event metadata
* Mailer - for sending emails (and where the templates are configured)
* NetworkAccess - only if `send_network_credentials` is enabled

## Configuration

```yaml
  zone_ids_to_target:       ["zone-id-here"]
  module_to_target:         "Bookings_1"
  module_status_to_scrape:  "bookings"
  event_filter:             "occurs_today"
  email_template_group:     "events"
  email_template:           "welcome"
  send_network_credentials: false
```

## Reply-To

Event emails set a `Reply-To` header so replies reach a useful person rather than
the no-reply sender address. By default the reply-to is the **event organiser**
(the event host). This requires no configuration.

This default can be overridden per-template (a `reply_to` field on the template
metadata), tenant-wide (the `reply_to` setting on the Template Mailer), or for all
mail (the `reply_to` setting on the SMTP Mailer). See the Template Mailer readme
for the full precedence cascade.
