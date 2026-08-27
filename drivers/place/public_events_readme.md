# Public Events Readme

Docs on how to configure the PlaceOS Public Events driver.
This driver publishes the events that have been marked public in Concierge so that they can be read by people who have not signed in, and lets those people register to attend.

* Publishes the public events from the system's calendar as the `public_events` status
* Exposes only a limited set of event fields, everything else is withheld
* Provides `register_attendee` so a guest can add themselves to a public event


## Requirements

Requires the following drivers in the same system:

* Bookings - reads the events on the system's calendar
* Calendar - adds guests to an event when they register
* StaffAPI - reads the publish state of each event

**CRITICAL:** the system must have its **calendar email** configured. Without it the driver cannot add guests to events and every registration attempt will fail.


## Publishing an Event

Whether an event appears publicly is controlled from the **Concierge UI**, on the event itself. It is not controlled by this driver and it is not a calendar setting.

| Concierge option | Published? |
| --- | --- |
| Publish (Public) | **Yes** |
| Publish (Internal) | No |
| Draft | No |
| Nothing set | No |

Only "Publish (Public)" is treated as public. "Publish (Internal)" makes an event joinable by people signed in to your own tenant, which is not safe to hand out to anonymous visitors, so it is deliberately excluded.

Two further rules apply:

* An event marked **Private** on the calendar is never published, even if it is set to "Publish (Public)". Its title and host have already been hidden, so there is nothing useful or safe left to show.
* For a **recurring event**, publishing a single occurrence publishes only that occurrence. Publish the series itself if you want the whole series to appear.

Publishing and unpublishing take up to `metadata_refresh_minutes` (5 minutes by default) to appear. Call `update_public_events` if you need the change applied immediately.


## Settings

```yaml
# how often the driver re-checks which events are published, in minutes
# set to 0 to disable, publish changes will then only be picked up when the
# calendar itself changes, which can leave the public list out of date
metadata_refresh_minutes: 5
```


## What Gets Published

Only the following fields of a public event are exposed:

* `id`
* `title`
* `body`
* `event_start`
* `event_end`
* `location`
* `timezone`
* `all_day`

Attendees, the organiser, and every other event detail are never exposed.

The title and body are readable by anyone, including people who have not signed in. Organisers should be reminded not to put internal or sensitive detail in the description of an event they intend to publish.


## Public Access

This driver is intended to be placed in the same system as the public events calendar.

Callers who have not signed in can:

* read the `public_events` status
* call `register_attendee`

`update_public_events` is administrator-only and is not available to those callers.


## Functions

### `register_attendee(event_id, name, email) : Bool`

Adds a guest to a public calendar event as an attendee.

Returns `true` on success. Returns `false` if:

* the `event_id` is not a currently published event
* the system has no calendar email configured
* the event no longer exists on the calendar

```yaml
# Example call
function: register_attendee
args:
  event_id: "evt-abc-123"
  name:     "Alice Smith"
  email:    "alice@external.com"
```

### `update_public_events : Nil`

Administrator-only. Re-reads the calendar and refreshes the published list straight away, rather than waiting for the next scheduled refresh. Use it after publishing or unpublishing an event.


## Troubleshooting

| Symptom | Check |
| --- | --- |
| An event is missing from `public_events` | It is set to "Publish (Public)" in Concierge, not "Publish (Internal)" or "Draft". It is not marked private on the calendar. It is on this system's calendar. Up to 5 minutes may not have passed yet, run `update_public_events` to apply the change now. |
| A recurring event only shows one occurrence | Only that occurrence has been published. Publish the series to show all of them. |
| A recurring event shows no occurrences | The series has not been published, publishing an occurrence does not publish the series. |
| `register_attendee` returns `false` | The event is not currently published, the system has no calendar email configured, or the event has since been deleted from the calendar. |
| `public_events` is always empty | Confirm the Bookings, Calendar and StaffAPI drivers are all present in this system, and that the system's calendar actually has published events on it. |
