# Booking Checkin Helper Readme

Docs on how to configure the booking check-in helper.
This helper provides a simple method for asking users if they intend to attend their meeting.

* Bookings driver tracks room schedule and looks for sensors indicating if there is presence in the room
* Sensor driver like Vergesense Room Sensor exposes room presence
* Booking checkin helper monitors `Booking.current_pending` and `Booking.presence`
  * auto checks in if presence found
  * emails the host about the booking if they have not checked in


## Requirements

Requires the following drivers in the system

* Booking - for room state
* StaffAPI - for peoples names
* Mailer - for querying the host if they will be using the room
* (some sensor driver for Booking driver to obtain presence state from)


## Usage

The driver generates a guest JWT and listens for a signal on path `"#{control_system.id}/guest/bookings/prompted"`
You signal via `POST /api/engine/v2/signal?channel=control_system_id/guest/bookings/prompted`
That signal is expected to have a payload of
```json
{"id": "event_id", "check_in": true / false}
```

To build the email with the links to your frontend interfaces you need to create an email template:
(email templates live on the mailer driver, this can be a dedicated SMTP driver or the Calendar driver, depending on Suncorp preferences)

```yaml
email_templates:
  booking:
    check_in_prompt:
      subject: Reminder about your meeting: %{meeting_summary}
      html: >
        <html><body>
        click here to <a href="https://corp.com/booking-confirmation?jwt=%{jwt}&system_id=%{system_id}&event_id=%{event_id}&check_in=false">release your booking</a>
        <br />
        click here to <a href="https://corp.com/booking-confirmation?jwt=%{jwt}&system_id=%{system_id}&event_id=%{event_id}&check_in=true">check-in your booking</a>
        </body></html>
```

The variables available to mix into the email template are:
      jwt
      host_email
      host_name
      event_id
      system_id
      meeting_room_name
      meeting_summary
      meeting_datetime
      meeting_time
      meeting_date
      check_in_url
      no_show_url

The urls above are optional, i.e. https://corp.com/booking-confirmation from the template, if you want to configure this as a driver setting vs in the template.
