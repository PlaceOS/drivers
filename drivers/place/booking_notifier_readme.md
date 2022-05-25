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


## Template configuration on Mailer

There are two templates that are expected:

* `booking_notify` (the booking owner booked the asset)
* `booked_by_notify` (someone booked on the owners behalf)

```yaml
email_templates:
  bookings:
    booking_notify:
      subject: Thank you for booking a desk
      html: >
        <html><body>
        your desk %{asset_id} has been booked for %{start_date}
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
