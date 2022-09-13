require "placeos-driver/spec"
require "uuid"

DriverSpecs.mock_driver "Place::UsagePusher" do
  system({
    StaffAPI: {StaffAPIMock},
    Bookings: {BookingsMock},
  })

  # Start a new meeting
  exec(:count).get.should eq 0
  bookings = system(:Bookings).as(BookingsMock)
  bookings.new_meeting
  exec(:count).get.should eq 0
  bookings.next_people_count

  # Update the people counts
  bookings.next_people_count
  bookings.next_people_count
  bookings.next_people_count
  bookings.next_people_count
  exec(:count).get.should eq 0

  # End the meeting
  bookings.new_meeting
  sleep 0.1

  exec(:count).get.should eq 1

  # check the update that was applied
  system(:StaffAPI)[:patched_with][2].should eq({
    "people_count" => {
      "min"     => 1,
      "max"     => 10,
      "median"  => 2,
      "average" => 3.4,
    },
  })
end

# :nodoc:
class BookingsMock < DriverSpecs::MockDriver
  @people_count_index : Int32 = 0
  @people_counts : Array(Int32) = [10, 1, 2, 3, 1]

  def next_people_count : Nil
    self[:status] = "busy"
    self[:people_count] = @people_counts[@people_count_index]
    @people_count_index += 1
  end

  def new_meeting : Nil
    self[:current_booking] = {
      event_id: UUID.random.to_s,
    }
    self[:status] = "pending"
  end
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  @people_count_index : Int32 = 0
  @people_counts : Array(Int32) = [10, 1, 2, 3, 1]

  def patch_event_metadata(system_id : String, event_id : String, metadata : JSON::Any)
    self[:patched_with] = {system_id, event_id, metadata}
    true
  end
end
