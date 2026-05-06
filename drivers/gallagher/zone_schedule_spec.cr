require "placeos-driver/spec"
require "uuid"

DriverSpecs.mock_driver "Gallagher::ZoneSchedule" do
  system({
    Gallagher: {GallagherMock},
    Bookings:  {BookingsMock},
  })

  bookings = system(:Bookings).as(BookingsMock)
  gallagher = system(:Gallagher).as(GallagherMock)

  # Start a new meeting
  exec(:count).get.should eq 0
  bookings.new_meeting
  sleep 1500.milliseconds # apply_new_state schedules a 1s reconciliation
  exec(:count).get.should eq 1

  # check the update that was applied
  system(:Gallagher)[:state].should eq(["free", "1234"])

  # host should now have access to the configured security_groups (a single
  # group "access-group" is provided by the spec runner)
  gallagher.access_for("ch-host").should contain("group-access-group")

  bookings.presence(true)
  sleep 500.milliseconds
  exec(:count).get.should eq 1
  system(:Gallagher)[:state].should eq(["free", "1234"])

  bookings.end_meeting
  sleep 1500.milliseconds # wait for the reconciliation schedule to fire
  exec(:count).get.should eq 1
  system(:Gallagher)[:state].should eq(["free", "1234"])

  # meeting ended → host should no longer be in the access group
  gallagher.access_for("ch-host").should_not contain("group-access-group")

  # ----- pre-existing access is left untouched on grant + revoke cycles -----
  gallagher.set_existing_access("ch-existing", "group-access-group")
  bookings.new_meeting_with_host("existing.user@example.com")
  sleep 1500.milliseconds

  # we shouldn't have called add for the user (they were already a member)
  gallagher.add_calls_for("ch-existing").should eq(0)
  gallagher.access_for("ch-existing").should contain("group-access-group")

  bookings.end_meeting
  sleep 1500.milliseconds

  # we never tracked them, so we never remove them
  gallagher.access_for("ch-existing").should contain("group-access-group")
  gallagher.remove_calls_for("ch-existing").should eq(0)

  bookings.presence(false)
  sleep 500.milliseconds
  exec(:count).get.should eq 2
  system(:Gallagher)[:state].should eq(["locked", "1234"])

  bookings.disable_unlock
  sleep 500.milliseconds
  exec(:should_unlock_booking?).get.should_not eq true
end

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  def disable_unlock
    self[:current_booking] = {
      extended_properties: {
        "Don't Unlock" => "TRUE",
      },
    }
  end

  def new_meeting : Nil
    self[:host_email] = "host@example.com"
    self[:next_host] = ""
    self[:status] = "pending"
  end

  def new_meeting_with_host(email : String) : Nil
    self[:host_email] = email
    self[:next_host] = ""
    self[:status] = "pending"
  end

  def presence(state : Bool)
    self[:presence] = state
  end

  def end_meeting : Nil
    self[:status] = "free"
  end
end

# :nodoc:
class GallagherMock < DriverSpecs::MockDriver
  @cardholders : Hash(String, String) = {
    "host@example.com"          => "ch-host",
    "existing.user@example.com" => "ch-existing",
  }
  @memberships : Hash(String, Array(String)) = {} of String => Array(String)
  @add_calls : Hash(String, Int32) = Hash(String, Int32).new(0)
  @remove_calls : Hash(String, Int32) = Hash(String, Int32).new(0)

  def free_zone(zone_id : String | Int32)
    self[:state] = {:free, zone_id.to_s}
    true
  end

  def reset_zone(zone_id : String | Int32)
    self[:state] = {:locked, zone_id.to_s}
    true
  end

  # ----- helpers exposed to the spec block -----

  def set_existing_access(cardholder_id : String, zone_id : String) : Nil
    list = @memberships[cardholder_id] ||= [] of String
    list << zone_id unless list.includes?(zone_id)
  end

  def access_for(cardholder_id : String) : Array(String)
    @memberships[cardholder_id]? || [] of String
  end

  def add_calls_for(cardholder_id : String) : Int32
    @add_calls[cardholder_id]? || 0
  end

  def remove_calls_for(cardholder_id : String) : Int32
    @remove_calls[cardholder_id]? || 0
  end

  # ----- gallagher API surface used by zone_schedule.cr -----

  def card_holder_id_lookup(email : String) : String | Int64 | Nil
    @cardholders[email.downcase]?
  end

  # the driver passes the configured group name; we map name -> id
  def zone_access_id_lookup(name : String, exact_match : Bool = true) : String | Int64 | Nil
    "group-#{name}"
  end

  def zone_access_lookup(id : String | Int64)
    {id: id, name: id.to_s, description: ""}
  end

  def zone_access_member?(zone_id : String | Int64, card_holder_id : String | Int64) : String | Int64 | Nil
    list = @memberships[card_holder_id.to_s]?
    return nil unless list
    list.includes?(zone_id.to_s) ? "href-#{zone_id}-#{card_holder_id}" : nil
  end

  def zone_access_add_member(zone_id : String | Int64, card_holder_id : String | Int64, from_unix : Int64? = nil, until_unix : Int64? = nil)
    @add_calls[card_holder_id.to_s] = (@add_calls[card_holder_id.to_s]? || 0) + 1
    list = @memberships[card_holder_id.to_s] ||= [] of String
    list << zone_id.to_s unless list.includes?(zone_id.to_s)
    true
  end

  def zone_access_remove_member(zone_id : String | Int64, card_holder_id : String | Int64)
    @remove_calls[card_holder_id.to_s] = (@remove_calls[card_holder_id.to_s]? || 0) + 1
    list = @memberships[card_holder_id.to_s]?
    list.try(&.delete(zone_id.to_s))
    true
  end
end
