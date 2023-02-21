require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Chat::HealthRooms" do
  system({
    InstantConnect: {InstantConnectMock},
  })

  exec(:pool_size).get.should eq 0
  exec(:pool_target_size).get.should eq 10

  meeting = exec(:pool_checkout_conference).get
  raise "no meeting returned" unless meeting

  meeting["host_pin"].should eq "host-1234"
  meeting["guest_pin"].should eq "guest-1234"

  sleep 0.5

  system(:InstantConnect_1)[:created].should eq(11)
end

# :nodoc:
class InstantConnectMock < DriverSpecs::MockDriver
  @called = 0

  def create_meeting(room_id : String)
    @called += 1
    self[:created] = @called
    {
      space_id:    room_id,
      host_token:  "host-1234",
      guest_token: "guest-1234",
    }
  end
end
