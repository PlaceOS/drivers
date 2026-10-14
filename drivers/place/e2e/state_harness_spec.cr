require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::E2E::StateHarness" do
  # NOTE:: the transport writes `connected: true` once it is up, which is not
  # synchronised with the spec, so only states set through `exec` are asserted
  exec(:set_connected, false).get
  status[:connected].should eq(false)

  exec(:set_connected, true).get
  status[:connected].should eq(true)

  exec(:set_status, "power", true).get
  status[:power].should eq(true)

  exec(:set_status, "inputs", {hdmi: 1, names: ["a", "b"]}).get
  status[:inputs].should eq({"hdmi" => 1, "names" => ["a", "b"]})

  exec(:clear_status, "power").get
  status[:power]?.should be_nil
end
