# Floorsense Boooking Sync

This is a quick overview of how PlaceOS interacts with Floorsense to enable floorsense features such as desk check-in.


## System layout

You'll need the following drivers and corresponding modules added to a system to sync bookings between PlaceOS and Floorsense

* `PlaceOS Staff API` this provides access to PlaceOS API functions
* `Floorsense Desk Tracking` this implements the floorsense API functions
* `Floorsense Bookings Sync` this keeps the two systems in sync


## Sync Configuration

Plan IDs in Floorsense need to be mapped to zones in PlaceOS, this configuration should be configured in the `Floorsense Bookings Sync` driver

```yaml

floor_mappings:
  '1':
    building_id: zone-GAf3dfZq8
    level_id: zone-GAf5RN-ne
    name: Building Name - Level 16

# Timezone of the building
time_zone: Australia/Brisbane

# time in seconds between polling for changes
poll_rate: 3

```

NOTE:: this assumes that desk ids in Floorsense and PlaceOS match, which is desirable from a maintenance and support standpoint.

There are some additional settings for adding prefixes to desk names, but these should be avoided if at all possible


## Driver operation

The driver monitors a couple of things at once

* monitors for real-time changes occurring in PlaceOS Staff API
  * changes in booking state, bookings added or removed
* polls PlaceOS bookings periodically in case a booking was missed
* uses Floorsense websocket to detect new ad-hoc bookings, booking check-outs or check-ins

PlaceOS bookings are added to floorsense 1 day before the booking,
so todays and tomorrows bookings are kept in sync.


### PlaceOS Booking Created

1. Sync determines that a new Floorsense booking needs to be created
2. Checks the user exists in Floorsense and adds them if they don't
3. Checks the users card number is correct in Floorsense, updates this if not
4. Creates the booking in Floorsense


### PlaceOS Booking Deleted

1. Sync determines that the Floorsense booking needs to be removed
2. The Floorsense booking is released


### PlaceOS Booking Checked-in

1. Sync determines that the Floorsense booking needs to be confirmed
2. The Floorsense booking is confirmed, enabling power


### Floorsense Booking Created

1. Checks that the booking is an ad-hoc booking
2. Attempts to locate the equivalent user in PlaceOS
3. Creates the booking on behalf of the user in PlaceOS

Only ad-hoc bookings are created in PlaceOS.
All other booking types will be removed automatically as part of the sync if there are no matching PlaceOS bookings.


### Floorsense Booking Checked-in

1. Attempts to locate the booking in PlaceOS
2. Marks the booking as checked-in


### Floorsense Booking Checked-out

1. Attempts to locate the booking in PlaceOS
2. Changes the end time of the booking to now (so the booking has effectively ended)
3. This has the effect of freeing the desk
