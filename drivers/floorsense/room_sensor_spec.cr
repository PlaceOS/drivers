require "placeos-driver/spec"

DriverSpecs.mock_driver "Floorsense::RoomSensor" do
  system({
    Floorsense: {FloorsenseMock},
  })

  sleep 200.milliseconds

  status[:presence].should eq(true)
  status[:people].should eq(3)

  sensors = exec(:sensors).get.not_nil!.as_a
  sensors.size.should eq 2

  sensor = exec(:sensor, sensors[0]["mac"], sensors[0]["id"]).get
  sensors[0].should eq sensor
end

# :nodoc:
class FloorsenseMock < DriverSpecs::MockDriver
  def room_list(room_id : String | Int32 | Int64? = nil)
    raise "expected room id in test" unless room_id
    [{
      :cached        => Time.utc.to_unix,
      :name          => "test room",
      :roomid        => 1,
      :occupiedcount => 3,
      :capacity      => 8,
    }]
  end
end
