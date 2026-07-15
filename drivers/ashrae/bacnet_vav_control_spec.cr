require "placeos-driver/spec"

DriverSpecs.mock_driver "Ashrae::BACnetVAVControl" do
  system({
    Bookings: {BookingsMock},
    BACnet:   {BACnetMock},
  })

  settings({
    instance_type:     "multi_state_value",
    vav_ids:           [{object: 1234, instance: 1}],
    vav_off_delay_sec: 999_999, # effectively never auto-off during the on tests
    vav_off_state:     3,
    vav_on_state:      1,
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
    instance_type:     "multi_state_value",
    vav_ids:           [{object: 1234, instance: 1}],
    vav_off_delay_sec: 0,
    vav_off_state:     3,
    vav_on_state:      1,
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
  # Every configured VAV box is driven, in order.
  # ===========================================================

  settings({
    instance_type:     "multi_state_value",
    vav_ids:           [{object: 1234, instance: 1}, {object: 5678, instance: 2}],
    vav_off_delay_sec: 999_999,
    vav_off_state:     3,
    vav_on_state:      1,
  })
  sleep 100.milliseconds

  bacnet.reset
  exec(:turn_on_vav).get
  bacnet.writes.should eq([{1234, 1, 1}, {5678, 2, 1}])

  # ===========================================================
  # The on/off enum values are configurable (device-specific state maps).
  # ===========================================================

  settings({
    instance_type:     "multi_state_value",
    vav_ids:           [{object: 42, instance: 1}],
    vav_off_delay_sec: 999_999,
    vav_off_state:     2, # this device uses 2 = Off
    vav_on_state:      4, # and 4 = Standby to admit air
  })
  sleep 100.milliseconds

  bacnet.reset
  exec(:turn_on_vav).get
  bacnet.writes.should eq([{42, 1, 4}])

  bacnet.reset
  exec(:turn_off_vav).get
  bacnet.writes.should eq([{42, 1, 2}])
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
#   write_unsigned_int(vav.object, vav.instance, state, instance_type)
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
