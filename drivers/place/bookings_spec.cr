require "placeos-driver/spec"
require "placeos-driver/interface/sensor"

DriverSpecs.mock_driver "Place::Bookings" do
  system({
    Calendar: {CalendarMock},
    Sensor:   {SensorMock},
  })

  # Check it calculates state properly
  exec(:poll_events).get
  bookings = status[:bookings].as_a
  bookings.size.should eq(4)

  sleep 200.milliseconds

  status[:booked].should eq(true)
  status[:in_use].should eq(false)
  status[:pending].should eq(true)
  status[:current_pending].should eq(true)
  status[:next_pending].should eq(false)
  status[:status].should eq("pending")

  current_start = bookings[0]["event_start"]

  # Start a meeting
  exec(:start_meeting, current_start).get
  bookings = status[:bookings].as_a
  bookings.size.should eq(4)
  status[:booked].should eq(true)
  status[:in_use].should eq(true)
  status[:pending].should eq(false)
  status[:current_pending].should eq(false)
  status[:next_pending].should eq(false)
  status[:status].should eq("busy")

  # End a meeting
  exec(:end_meeting, current_start).get
  bookings = status[:bookings].as_a
  bookings.size.should eq(3)

  status[:booked].should eq(false)
  status[:in_use].should eq(false)
  status[:pending].should eq(false)
  status[:current_pending].should eq(false)
  status[:next_pending].should eq(false)
  status[:status].should eq("free")

  status[:people_count].should eq(12.0)
  status[:sensor_name].should eq("Mock People Count")
  status[:presence].should eq(true)
end

# :nodoc:
class SensorMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::Sensor

  alias Interface = PlaceOS::Driver::Interface

  def on_load
    self[:people_count] = 12.0
  end

  def sensors(type : String? = nil, mac : String? = nil, zone_id : String? = nil) : Array(Interface::Sensor::Detail)
    if type == "people_count"
      [Interface::Sensor::Detail.new(
        type: Interface::Sensor::SensorType::PeopleCount,
        value: 12.0,
        last_seen: Time.utc.to_unix,
        mac: "mock-people-count",
        id: nil,
        name: "Mock People Count",
        module_id: "mod-Sensor/1",
        binding: "people_count"
      )]
    else
      [] of Interface::Sensor::Detail
    end
  end

  def sensor(mac : String, id : String? = nil) : Interface::Sensor::Detail?
    nil
  end
end

# :nodoc:
class CalendarMock < DriverSpecs::MockDriver
  def on_load
    self[:checked_calendar] = nil
    self[:deleted_event] = nil
  end

  def delete_event(calendar_id : String, event_id : String, user_id : String? = nil)
    self[:deleted_event] = {calendar_id, event_id}
    @events = @events.reject { |event| event["id"] == event_id }
    nil
  end

  def list_events(
    calendar_id : String,
    period_start : Int64,
    period_end : Int64,
    time_zone : String? = nil,
    user_id : String? = nil,
    include_cancelled : Bool = false
  )
    self[:checked_calendar] = calendar_id
    @events
  end

  @events : Array(Hash(String, Array(Hash(String, String)) | Bool | Int64 | String | Array(Nil))) = [
    {
      "event_start" => 10.minutes.ago.to_unix,
      "event_end"   => 20.minutes.from_now.to_unix,
      "id"          => "2hg6c13j9ko8hiugmuj8n3jtap_20200804T000000Z",
      "host"        => "jeremy@place.nology",
      "title"       => "A Standup",
      "description" => "",
      "attendees"   => [
        {
          "name"  => "alexandre@place.nology",
          "email" => "alexandre@place.nology",
        },
        {
          "name"  => "candy@place.nology",
          "email" => "candy@place.nology",
        },
        {
          "name"  => "viv@place.nology",
          "email" => "viv@place.nology",
        },
        {
          "name"  => "steve@place.nology",
          "email" => "steve@place.nology",
        },
        {
          "name"  => "jeremy@place.nology",
          "email" => "jeremy@place.nology",
        },
      ],
      "private"     => false,
      "recurring"   => false,
      "all_day"     => false,
      "timezone"    => "UTC",
      "attachments" => [] of Nil,
    },
    {
      "event_start" => 40.minutes.from_now.to_unix,
      "event_end"   => 1.hour.from_now.to_unix,
      "id"          => "2hg6c13j9ko8hiugmuj8n3jtap_20200806T000000Z",
      "host"        => "jeremy@place.nology",
      "title"       => "A Standup",
      "description" => "",
      "attendees"   => [
        {
          "name"  => "alexandre@place.nology",
          "email" => "alexandre@place.nology",
        },
        {
          "name"  => "candy@place.nology",
          "email" => "candy@place.nology",
        },
        {
          "name"  => "viv@place.nology",
          "email" => "viv@place.nology",
        },
        {
          "name"  => "steve@place.nology",
          "email" => "steve@place.nology",
        },
        {
          "name"  => "jeremy@place.nology",
          "email" => "jeremy@place.nology",
        },
      ],
      "private"     => false,
      "recurring"   => false,
      "all_day"     => false,
      "timezone"    => "UTC",
      "attachments" => [] of Nil,
    },
    {
      "event_start" => 4.hour.from_now.to_unix,
      "event_end"   => 5.hour.from_now.to_unix,
      "id"          => "0e1f5n6a898n85eo9gsj169kh1_20200806T010000Z",
      "host"        => "shreya@external.com",
      "title"       => "Place weekly catchup",
      "description" => "",
      "attendees"   => [
        {
          "name"  => "Michael",
          "email" => "michael@external.com",
        },
        {
          "name"  => "Glenn",
          "email" => "glenn@external.com",
        },
        {
          "name"  => "Shreya",
          "email" => "shreya@external.com",
        },
        {
          "name"  => "jeremy@place.nology",
          "email" => "jeremy@place.nology",
        },
        {
          "name"  => "Lisa",
          "email" => "lisa@external.com",
        },
        {
          "name"  => "Sheshank",
          "email" => "sheshank@external.com",
        },
        {
          "name"  => "steve@place.nology",
          "email" => "steve@place.nology",
        },
        {
          "name"  => "Zinoca",
          "email" => "zain@external.com",
        },
        {
          "name"  => "Aymie",
          "email" => "aymie@external.com",
        },
      ],
      "private"     => false,
      "recurring"   => false,
      "all_day"     => false,
      "timezone"    => "UTC",
      "attachments" => [] of Nil,
    },
    {
      "event_start" => 10.hours.from_now.to_unix,
      "event_end"   => 11.hours.from_now.to_unix,
      "id"          => "d8n8u5a5u8j45jgm5248ir49qs_20200806T010000Z",
      "host"        => "jeremy@place.nology",
      "title"       => "PlaceOS Standup",
      "description" => "Regular Standup to discuss Engine2 Development and Product Requirements.",
      "attendees"   => [
        {
          "name"  => "caspian@place.nology",
          "email" => "caspian@place.nology",
        },
        {
          "name"  => "viv@place.nology",
          "email" => "viv@place.nology",
        },
        {
          "name"  => "Kim",
          "email" => "kim@place.nology",
        },
        {
          "name"  => "William",
          "email" => "w.le@place.nology",
        },
        {
          "name"  => "jeremy@place.nology",
          "email" => "jeremy@place.nology",
        },
        {
          "name"  => "Shane",
          "email" => "shane@place.nology",
        },
        {
          "name"  => "steve@place.nology",
          "email" => "steve@place.nology",
        },
      ],
      "private"     => false,
      "recurring"   => false,
      "all_day"     => false,
      "timezone"    => "UTC",
      "attachments" => [] of Nil,
    },
  ]
end
