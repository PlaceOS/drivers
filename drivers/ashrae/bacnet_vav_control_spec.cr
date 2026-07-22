require "placeos-driver/spec"

DriverSpecs.mock_driver "Ashrae::BACnetVAVControl" do
  system({
    Bookings:     {BookingsMock},
    BACnet:       {BACnetMock},
    StaffAPI:     {StaffAPIMock},
    DeskBookings: {DeskBookingsMock},
  })

  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    999_999, # effectively never auto-off during the on tests
    vav_sensor_delay_sec: 0,       # sensor turns on instantly unless a test opts in
    vav_off_state:        3,
    vav_on_state:         1,
  })

  bookings = system(:Bookings).as(BookingsMock)
  bacnet = system(:BACnet).as(BACnetMock)

  # ===========================================================
  # Direct control — turn_on_vav / turn_off_vav write the configured
  # multi-state enum values straight to the BACnet box.
  # ===========================================================

  bacnet.reset
  exec(:turn_on_vav).get
  # {device object, instance, value} — the "on" state (1) is written
  bacnet.writes.should eq([{1234, 1, 1}])
  status[:vav_active].should eq true

  bacnet.reset
  exec(:turn_off_vav).get
  # the "off" state (3) is written
  bacnet.writes.should eq([{1234, 1, 3}])
  status[:vav_active].should eq false

  # ===========================================================
  # A booking turns the air on. Any status other than "free" means the
  # room is booked, so airflow is enabled regardless of occupancy.
  # ===========================================================

  bacnet.reset
  bookings.set_status("busy")
  sleep 500.milliseconds

  bacnet.values_written.last?.should eq 1
  status[:vav_active].should eq true

  # ===========================================================
  # A live sensor detecting presence turns the air on (even when not booked).
  # (sensor delay is 0 here, debounce behaviour is covered separately below)
  # ===========================================================

  bacnet.reset
  bookings.set_status("free") # not booked
  bookings.set_stale(false)   # sensor is reporting
  bookings.set_presence(true) # someone is in the room
  sleep 500.milliseconds

  bacnet.values_written.last?.should eq 1
  status[:vav_active].should eq true

  # ===========================================================
  # Fail-safe: a stale sensor is treated as "occupied" so the air stays on
  # rather than shutting off a space that might be in use.
  # ===========================================================

  bacnet.reset
  bookings.set_status("free")  # not booked
  bookings.set_presence(false) # sensor last reported empty...
  bookings.set_stale(true)     # ...but the sensor has gone stale
  sleep 500.milliseconds

  bacnet.values_written.last?.should eq 1
  status[:vav_active].should eq true

  # ===========================================================
  # Free + empty + a working sensor turns the air off once the off delay
  # elapses. Reconfigure with a zero delay so the off timer fires promptly.
  # ===========================================================

  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    0,
    vav_sensor_delay_sec: 0,
    vav_off_state:        3,
    vav_on_state:         1,
  })
  sleep 100.milliseconds

  bacnet.reset
  bookings.set_stale(false)    # sensor working
  bookings.set_presence(false) # nobody present
  bookings.set_status("free")  # not booked
  sleep 500.milliseconds

  # the "off" state (3) was written and the digital twin reflects it
  bacnet.values_written.last?.should eq 3
  status[:vav_active].should eq false

  # ===========================================================
  # Sensor debounce: a working sensor detecting presence does NOT switch the
  # air on immediately — it must stay occupied for vav_sensor_delay_sec first.
  # ===========================================================

  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    999_999,
    vav_sensor_delay_sec: 2, # 2 second debounce
    vav_off_state:        3,
    vav_on_state:         1,
  })
  sleep 100.milliseconds

  # baseline: empty room, air off (state carried from the off test above)
  bacnet.reset
  bookings.set_presence(true) # someone appears
  sleep 500.milliseconds      # well within the 2s debounce window

  # nothing written yet — we're waiting to confirm the presence is real
  bacnet.writes.should be_empty
  status[:vav_pending_on].should eq true
  status[:vav_active].should eq false

  # once the debounce elapses (presence held throughout) the air switches on
  sleep 2.seconds
  bacnet.values_written.last?.should eq 1
  status[:vav_active].should eq true
  status[:vav_pending_on].should eq false

  # ===========================================================
  # A booking still switches the air on instantly, ignoring the sensor delay.
  # ===========================================================

  # baseline: drop presence so the air is no longer active, then confirm a
  # booking bypasses the (now very long) debounce entirely
  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    999_999,
    vav_sensor_delay_sec: 999_999, # sensor would essentially never fire
    vav_off_state:        3,
    vav_on_state:         1,
  })
  sleep 100.milliseconds

  bookings.set_presence(false) # room empties -> air no longer active
  sleep 300.milliseconds

  bacnet.reset
  bookings.set_status("busy") # booked
  sleep 500.milliseconds

  # instant, despite the enormous sensor delay
  bacnet.values_written.last?.should eq 1
  status[:vav_active].should eq true

  # ===========================================================
  # Sensor flap resets the debounce: presence going false then true again
  # restarts the countdown, so a brief blip never accumulates to a turn on.
  # ===========================================================

  # start from a clean OFF baseline: clear the booking and empty the room with a
  # zero off-delay so the air actually switches off before we exercise the flap
  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    0,
    vav_sensor_delay_sec: 999_999,
    vav_off_state:        3,
    vav_on_state:         1,
  })
  sleep 100.milliseconds
  bookings.set_status("free")  # clear the booking
  bookings.set_presence(false) # empty the room -> air switches off (0s delay)
  sleep 300.milliseconds

  # now stretch the off-delay back out so nothing auto-changes during the flap
  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    999_999,
    vav_sensor_delay_sec: 999_999,
    vav_off_state:        3,
    vav_on_state:         1,
  })
  sleep 100.milliseconds

  bacnet.reset
  bookings.set_presence(true) # blip on -> debounce arms
  sleep 300.milliseconds
  status[:vav_pending_on].should eq true
  bacnet.writes.should be_empty

  bookings.set_presence(false) # blip clears -> debounce cancelled
  sleep 300.milliseconds
  status[:vav_pending_on].should eq false

  bookings.set_presence(true) # occupied again -> a fresh countdown starts
  sleep 300.milliseconds
  status[:vav_pending_on].should eq true
  # still nothing written: the earlier blip did not count toward the delay
  bacnet.writes.should be_empty
  status[:vav_active].should eq false

  # ===========================================================
  # vav_disable_sensor: the presence sensor is ignored entirely — the room only
  # counts as "in use" when booked, so sensor presence can neither hold the air
  # on nor turn it on.
  # ===========================================================

  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    0, # turn off promptly once "not in use"
    vav_sensor_delay_sec: 0,
    vav_disable_sensor:   true,
    vav_off_state:        3,
    vav_on_state:         1,
  })
  sleep 100.milliseconds

  # known OFF baseline (also clears any pending timers) and a normalised sensor
  exec(:turn_off_vav).get
  bookings.set_presence(false)
  sleep 200.milliseconds

  # presence alone can NOT turn the air on while the sensor is disabled
  bacnet.reset
  bookings.set_presence(true) # sensor sees someone -> ignored
  sleep 500.milliseconds

  status[:vav_active].should eq false
  bacnet.values_written.should_not contain(1) # never switched on

  # a booking still drives the air on, sensor state irrelevant
  bacnet.reset
  bookings.set_status("busy")
  sleep 500.milliseconds

  bacnet.values_written.last?.should eq 1
  status[:vav_active].should eq true

  # ending the booking turns it back off even though presence is still true
  bacnet.reset
  bookings.set_status("free")
  sleep 500.milliseconds

  bacnet.values_written.last?.should eq 3
  status[:vav_active].should eq false

  # ===========================================================
  # Every configured VAV box is driven, in order.
  # ===========================================================

  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}, {object: 5678, instance: 2}],
    vav_off_delay_sec:    999_999,
    vav_sensor_delay_sec: 0,
    vav_off_state:        3,
    vav_on_state:         1,
  })
  sleep 100.milliseconds

  bacnet.reset
  exec(:turn_on_vav).get
  bacnet.writes.should eq([{1234, 1, 1}, {5678, 2, 1}])

  # ===========================================================
  # The on/off enum values are configurable (device-specific state maps).
  # ===========================================================

  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 42, instance: 1}],
    vav_off_delay_sec:    999_999,
    vav_sensor_delay_sec: 0,
    vav_off_state:        2, # this device uses 2 = Off
    vav_on_state:         4, # and 4 = Standby to admit air
  })
  sleep 100.milliseconds

  bacnet.reset
  exec(:turn_on_vav).get
  bacnet.writes.should eq([{42, 1, 4}])

  bacnet.reset
  exec(:turn_off_vav).get
  bacnet.writes.should eq([{42, 1, 2}])

  # ===========================================================
  # Desk bookings: a checked-in desk in this space keeps the air on, even
  # though the room isn't booked and the presence sensor is disabled.
  # ===========================================================

  settings({
    instance_type:        "multi_state_value",
    vav_ids:              [{object: 1234, instance: 1}],
    vav_off_delay_sec:    0, # turn off promptly once "not in use"
    vav_sensor_delay_sec: 0,
    vav_disable_sensor:   true, # desks are the only thing driving state here
    vav_off_state:        3,
    vav_on_state:         1,
    desk_ids:             ["desk-6.67.25"],
  })
  sleep 100.milliseconds

  desks = system(:DeskBookings).as(DeskBookingsMock)

  # nobody checked in at the desks we care about -> air off
  bacnet.reset
  desks.set_checked_in(false)
  exec(:check_desk_usage).get.should eq false
  sleep 200.milliseconds

  status[:desk_checked_in].should eq false
  bacnet.values_written.last?.should eq 3
  status[:vav_active].should eq false

  # our desk gets checked into -> air on immediately
  bacnet.reset
  desks.set_checked_in(true)
  exec(:check_desk_usage).get.should eq true
  sleep 200.milliseconds

  status[:desk_checked_in].should eq true
  bacnet.values_written.last?.should eq 1
  status[:vav_active].should eq true

  # a checked-in desk that isn't in our list is ignored -> air back off
  bacnet.reset
  desks.set_asset_id("desk-1.02.3")
  exec(:check_desk_usage).get.should eq false
  sleep 200.milliseconds

  status[:desk_checked_in].should eq false
  bacnet.values_written.last?.should eq 3
  status[:vav_active].should eq false
end

# :nodoc:
# Mocks the Place::Bookings driver bindings the VAV controller subscribes to:
#   status       - "free" vs anything-else (booked)
#   sensor_stale - is the presence sensor reporting recently
#   presence     - is someone currently in the room
class BookingsMock < DriverSpecs::MockDriver
  def set_status(state : String) : Nil
    self[:status] = state
  end

  def set_stale(stale : Bool) : Nil
    self[:sensor_stale] = stale
  end

  def set_presence(present : Bool) : Nil
    self[:presence] = present
  end
end

# :nodoc:
# Mocks the Ashrae::BACnetSecureConnect driver. The VAV controller only ever
# calls write_unsigned_int against it, so we record those writes for assertion.
# The controller invokes it as:
#   write_unsigned_int(vav.object, vav.instance, state, instance_type, priority)
class BACnetMock < DriverSpecs::MockDriver
  @writes = [] of Tuple(Int32, Int32, Int32)

  def write_unsigned_int(object : Int32, instance : Int32, value : Int32, object_type : String, priority : Int32? = nil)
    @writes << {object, instance, value}
    self[:last_value] = value
    self[:write_count] = @writes.size
    value
  end

  # ----- helpers exposed to the spec block -----

  def reset : Nil
    @writes.clear
    self[:last_value] = nil
    self[:write_count] = 0
  end

  def writes : Array(Tuple(Int32, Int32, Int32))
    @writes
  end

  def values_written : Array(Int32)
    @writes.map &.[2]
  end
end

# :nodoc:
# Mocks Place::StaffAPI, the VAV controller only uses `zone` to work out which
# of the system zones is the level (so it can query desk bookings on it)
class StaffAPIMock < DriverSpecs::MockDriver
  def zone(zone_id : String)
    tags = case zone_id
           when "zone-level"    then ["level"]
           when "zone-building" then ["building"]
           when "zone-org"      then ["org"]
           else                      ["room"]
           end
    {id: zone_id, name: zone_id, tags: tags}
  end
end

# :nodoc:
# Mocks Place::DeskBookingsLocations#device_locations, response shape copied
# from a live system (names and emails are dummies)
class DeskBookingsMock < DriverSpecs::MockDriver
  @checked_in : Bool = false
  @asset_id : String = "desk-6.67.25"

  def set_checked_in(state : Bool) : Nil
    @checked_in = state
  end

  def set_asset_id(asset_id : String) : Nil
    @asset_id = asset_id
  end

  def device_locations(zone_id : String, location : String? = nil)
    return [] of Nil if location && location != "booking"
    raise "unexpected zone queried: #{zone_id}" unless zone_id == "zone-level"

    [
      {
        location:    "booking",
        type:        "desk",
        checked_in:  @checked_in,
        asset_id:    @asset_id,
        booking_id:  4462,
        building:    "zone-building",
        level:       "zone-level",
        ends_at:     1784730540,
        started_at:  1784644200,
        duration:    86340,
        mac:         "user-HoWSkZDC0IpGFN",
        staff_email: "jane.doe@example.com",
        staff_name:  "Jane Doe",
        map_id:      @asset_id,
      },
      {
        location:    "booking",
        type:        "desk",
        checked_in:  false,
        asset_id:    "desk-6.28.2",
        booking_id:  4540,
        building:    "zone-building",
        level:       "zone-level",
        ends_at:     1784701800,
        started_at:  1784683800,
        duration:    18000,
        mac:         "user-GTJXjvTHMXNeCl",
        staff_email: "john.smith@example.com",
        staff_name:  "John Smith",
        map_id:      "desk-6.28.2",
      },
    ]
  end
end
