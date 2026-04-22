# Public Events Readme

Docs on the PlaceOS Public Events driver.
This driver filters the Bookings event cache down to publicly visible events and handles guest registration, enabling unauthenticated access to selected calendar events.

* Subscribes to the Bookings driver's `:bookings` status and filters events where `private` is `false`
* Caches the filtered set of public events (with a reduced set of safe fields) as the `:public_events` status
* Provides a `register_attendee` function for appending external (guest) attendees to a public event via the Calendar driver


## Requirements

Requires the following drivers in the same system:

* Bookings - for the room/calendar event cache and polling
* Calendar - for reading and updating calendar events when registering attendees

The system must also have a calendar email configured (used as the `calendar_id` when calling the Calendar driver).


## How It Works

1. The Bookings driver polls the calendar and publishes all events to its `:bookings` status
2. PublicEvents receives the update via the subscription binding and filters to non-private events (`private == false`)
3. The filtered events are stored in `:public_events` with only safe, non-sensitive fields exposed: `id`, `title`, `body`, `event_start`, `event_end`, `location`, `timezone`, `all_day`
4. When a guest registers, `register_attendee` checks the event is in the public set, fetches it from the Calendar driver, appends the attendee, and writes it back


## Public System Usage

This driver is intended to be placed in the same system as the public events calendar. It follows the same public system access pattern as the WebRTC driver — a Guest JWT is issued to the caller after passing the invisible Google reCAPTCHA, granting read access to the `:public_events` status and the ability to call `register_attendee`.


## Functions

### `register_attendee(event_id, name, email) : Bool`

Appends an external attendee to a public calendar event.

* Returns `true` on success
* Returns `false` if the `event_id` is not in the public events set, or if the system has no calendar email configured

```yaml
# Example call
function: register_attendee
args:
  event_id: "evt-abc-123"
  name:     "Alice Smith"
  email:    "alice@external.com"
```

### `update_public_events : Nil`

Administrator-only. Triggers a Bookings re-poll and repopulates the public events cache via the subscription binding.