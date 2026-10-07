# Booking Notifier Readme

Docs on how to configure the booking notifier helper.
This helper provides a simple way to notify users of bookings.

* The notifier monitors for new asset bookings (defaults to desks)
* periodically checks for new bookings
* for buildings or floors, it notifies a selection of: pre-defined email addresses, the owner of the booking and / or the manager of the booking owner


## Requirements

Requires the following drivers in the system

* StaffAPI - for querying bookings
* Mailer - for sending emails, this also will be where the templates are configured
* Calendar - for querying a users manager (only if manager notification is desired)


## Booking Notifier Configuration

```yaml
  # How do we want dates to be formatted in the email template
  timezone:         "Australia/Sydney"
  date_time_format: "%c"
  time_format:      "%l:%M%p"
  date_format:      "%A, %-d %B"

  # What type of asset are we notifying people about
  booking_type:        "desk"

  # Do we want to be emailing out attachments?
  disable_attachments: true

  # what zones are we notifying about?
  notify: {
    # You can configure notification settings for building and floor zones
    zone_id1: {
      # name of the building or floor that will be in the email template
      name:                 "Sydney Building 1",
      # optional list of emails you always want to be notified of bookings in this zone
      email:                ["concierge@place.com"],
      # do we want to notify the booking owners manager?
      notify_manager:       true,
      # do we want to notify the booking owner?
      notify_booking_owner: true,
    },
    zone_id2: {
      name:                 "Melb Building",
      attachments:          {"file-name.pdf" => "https://s3/your_file.pdf"},
      notify_booking_owner: true,
    },
  }
```


## Reply-To

Booking notification emails set a `Reply-To` header so replies reach a useful
person rather than the no-reply sender address. By default the reply-to is the
**booking creator** (`booked_by_email`). This requires no configuration.

This default can be overridden per-template (a `reply_to` field on the template
metadata), tenant-wide (the `reply_to` setting on the Template Mailer), or for all
mail (the `reply_to` setting on the SMTP Mailer). See the Template Mailer readme
for the full precedence cascade.


## Booking reminders

The driver can email the booking owner a reminder before their booking starts.
Reminders are driven by a list of offsets and a scheduled sweep, because a plain
cron entry cannot express "3 days before a booking that starts on Thursday".

```yaml
  # Minutes before the booking start time to email the booking owner.
  # One reminder is sent per entry, an empty list disables reminders.
  # i.e. [4320, 60, 15] => 3 days, 1 hour and 15 minutes before the booking
  reminders_before_booking: [4320, 60]

  # Cron schedule for the sweep that checks bookings against the offsets above.
  # Run it more often than reminder_grace_minutes so no reminder is missed.
  reminder_schedule: "*/15 * * * *"

  # How long after an offset a reminder may still be sent. Covers the sweep
  # interval and any driver downtime - a reminder outside this window is
  # skipped rather than sent late.
  reminder_grace_minutes: 30
```

* Recipients: only the booking owner (`user_email`), replies go to the booking
  creator as per the Reply-To section above. A zone without
  `notify_booking_owner: true` gets no reminders, matching the booking
  notification emails.
* The sweep queries bookings of the driver's `booking_type`, so a reminder
  reaches whichever kind of booking the instance is configured for - deploy an
  instance per type (`desk`, `locker`, `visitor`, ...). For a visitor booking
  `user_email` is the host, so the reminder goes to the host. With
  `unique_templates: true` the trigger and template become
  `bookings.booking_reminder_<booking_type>` (e.g. `booking_reminder_visitor`),
  so each type can have its own template.
* Already checked-in bookings are skipped, as are bookings created after their
  reminder time had passed (booking them would not have triggered a reminder).
* Each reminder is sent once per booking. The sent state is stored in the
  driver status under `reminders_sent`, so a restart of the driver does not
  re-send reminders.
* The schedule sweeps immediately when the driver starts or its settings
  change, then on the cron interval. A restart therefore checks for due
  reminders straight away instead of waiting up to `reminder_schedule`.
* Reminder windows are calculated from the booking's Unix start time, so the
  booking timezone does not change when a reminder fires.
* Zone `attachments` behave as they do on booking notifications: the file is
  attached when `disable_attachments` is false, and `attachment_name` /
  `attachment_url` merge fields are always available for linking to it.
* The reminder template does not provide `network_username` /
  `network_password` - a reminder must not rotate the password that the
  booking notification already handed out.

A sweep can also be triggered manually with the `send_booking_reminders`
function (level `Support`) while configuring or troubleshooting.


## Template configuration on Mailer

The templates expected are:

* `booking_notify` (the booking owner booked the asset)
* `booked_by_notify` (someone booked on the owners behalf)
* `rejected` (the booking was rejected)
* `cancelled` (the booking was cancelled)
* `booking_reminder` (reminder ahead of the booking starting)

```yaml
email_templates:
  bookings:
    booking_notify:
      subject: Thank you for booking a desk
      html: >
        <html><body>
        your desk %{asset_id} has been booked for %{start_date}
        </body></html>
    booking_reminder:
      subject: Reminder - your desk booking
      html: >
        <html><body>
        your desk %{asset_id} starts at %{start_time} on %{start_date}
        </body></html>
```

The variables available to mix into the email template are:
      booking_id
      start_time (formatted as per Booking Notifier Configuration)
      start_date
      start_datetime
      end_time
      end_date
      end_datetime
      starting_unix
      asset_id
      user_id   (where user is the booking owner)
      user_email
      user_name
      reason    (or booking title)
      level_zone
      building_zone
      building_name
      approver_name
      approver_email
      booked_by_name
      booked_by_email
      attachment_name
      attachment_url
      reminder_offset_minutes  (booking_reminder template only - the offset
                                in minutes that triggered this reminder)

`network_username` and `network_password` are available to the booking
notification templates when the zone enables `include_network_credentials`,
but are deliberately not offered on `booking_reminder`.
