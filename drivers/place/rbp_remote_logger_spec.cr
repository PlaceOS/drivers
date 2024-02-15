require "placeos-driver/spec"
require "uuid"

DriverSpecs.mock_driver "Place::RbpRemoteLogger" do
  subpayload = {"id" => "1"}

  payload = {
    "id"        => "1",
    "type"      => "3",
    "subtype"   => "4",
    "timestamp" => 5,
    "raw"       => subpayload,
    "data"      => subpayload,
    "metadata"  => subpayload,
  }

  5.times do
    payload.merge!({"device_id" => UUID.random.to_s})
    entry = exec(:post_event, payload.to_json).get.not_nil!
  end

  status.[:entries].as_h.keys.size.should eq 5
end
