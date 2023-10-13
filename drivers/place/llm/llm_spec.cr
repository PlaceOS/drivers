require "placeos-driver/spec"
require "placeos-driver/interface/chat_functions"

DriverSpecs.mock_driver "Place::LLM" do
  system({
    DeskBookings: {DeskMock},
    RoomBookings: {RoomMock},
  })

  sleep 200.milliseconds

  exec(:capabilities).get.should eq [
    {
      "id"         => "DeskBookings",
      "capability" => "provides methods listing current desk bookings and booking or allocating a new desk booking",
    },
    {
      "id"         => "RoomBookings",
      "capability" => "provides methods listing current meeting room bookings or events and booking new meetings or events",
    },
  ]

  system(:DeskBookings_1).function_schemas.should eq([
    {
      function: "list_of_levels",
      description: "returns the list of levels with available desks",
      parameters: {} of String => JSON::Any
    },
    {
      function: "book",
      description: "books a desk, you can optionally provide a preferred level or how many days from now if the booking is for tomorrow etc",
      parameters: {
        "level" => {
          "anyOf" => [{"type" => "null"}, {"type" => "string"}],
          "title" => "(String | Nil)",
          "default" => nil
        },
        "days_in_future" => {
          "type" => "integer",
          "format" => "Int32",
          "title" => "Int32",
          "default" => 0
        }
      }
    }
  ])
end

# :nodoc:
class DeskMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::ChatFunctions

  def capabilities : String
    "provides methods listing current desk bookings and booking or allocating a new desk booking"
  end

  @[Description("returns the list of levels with available desks")]
  def list_of_levels
    {"level 1", "level 2"}
  end

  @[Description("books a desk, you can optionally provide a preferred level or how many days from now if the booking is for tomorrow etc")]
  def book(level : String? = nil, days_in_future : Int32 = 0)
    "you've been allocated desk 123 on #{level || "level 2"}"
  end
end

# :nodoc:
class RoomMock < DriverSpecs::MockDriver
  include PlaceOS::Driver::Interface::ChatFunctions

  def capabilities : String
    "provides methods listing current meeting room bookings or events and booking new meetings or events"
  end

  def my_bookings(days_in_future : Int32 = 0)
    [{
      room:       "room@site.com",
      booking_id: "12345",
      title:      "Blah",
      organizer:  "Janis",
    }]
  end

  @[Description("returns the list of levels with available rooms")]
  def list_of_levels(number_of_attendees : Int32)
    {"level 1", "level 2"}
  end

  @[Description("books a room, you can optionally provide a preferred level or how many days from now if the booking is for tomorrow etc")]
  def book(number_of_attendees : Int32, level : String? = nil, days_in_future : Int32 = 0)
    "you've been allocated room studio 2 on #{level || "level 2"}"
  end
end
