# Template Mailer Readme

The Template Mailer renders metadata-defined email templates and forwards the
result to the next mailer in the chain (typically the SMTP Mailer). It is
normally configured as `Mailer_1`, with the SMTP driver as `Mailer_2`.

## Requirements

Requires the following drivers in the system:

* StaffAPI - for reading email template metadata from zones
* A downstream mailer (e.g. SMTP Mailer) as the next `Mailer` module in the chain

## Configuration

```yaml
  cache_timeout:    300              # seconds to cache templates for
  keep_if_not_seen: 6                # keep template fields for N updates if not seen
  timezone:         "Australia/Sydney"
  update_schedule:  "*/20 * * * *"   # cron schedule for refreshing template fields

  # Optional: a tenant-wide reply-to address. When set, it overrides the
  # reply-to on every templated email this mailer sends (see Reply-To below).
  # reply_to: "noreply@place.tech"
```

## Reply-To

System-generated emails set a `Reply-To` header so that when a recipient replies,
the reply reaches a useful person (or mailbox) rather than the no-reply sender
address.

The reply-to is resolved as a cascade. Each layer overrides the value passed
down to it, so the **highest configured layer wins**:

1. **SMTP Mailer `reply_to` setting** (highest) — a catch-all override applied to
   all outbound mail. See the SMTP Mailer readme.
2. **Template Mailer `reply_to` setting** — the tenant-wide override configured on
   this driver.
3. **Per-template `reply_to`** — a `reply_to` field on an individual email
   template's metadata.
4. **Host** (lowest / default) — the sending driver (Booking Notifier, Visitor
   Mailer, Event Mailer, etc.) sets the reply-to to the relevant person: the
   booking creator, the event organiser, or the visitor's host. This requires no
   configuration.

In other words, if nothing is configured the reply-to defaults to the host; a
per-template `reply_to` overrides the host; the Template Mailer setting overrides
the template; and an SMTP-level setting overrides everything.

A per-template reply-to is configured alongside the other template fields in zone
metadata, for example:

```yaml
email_templates:
  bookings:
    cancelled:
      subject: "Your booking was cancelled"
      reply_to: "concierge@place.com"   # optional per-template override
      html: >
        <html><body>...</body></html>
```
