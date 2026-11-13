require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::RemoteSetup" do
  panel = "DEV-3F9A0C12B7E4"
  command_binding = "device_#{panel}"

  it "registers devices" do
    status[:connected].should eq true
    status[:devices].as_h.empty?.should be_true

    exec(:register, panel, "booking-panel", nil).get
    # `remove_stale` publishes the devices without waiting for the interval
    exec(:remove_stale).get

    device = status[:devices][panel]
    device["id"].should eq panel
    device["app"].should eq "booking-panel"
    device.as_h.has_key?("config").should be_true
    device["config"].raw.should be_nil
  end

  it "rejects bad input" do
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:register, "", "control", nil).get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:register, "DEV-1", "phone", nil).get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:configure, "DEV-UNKNOWN", {system_id: "sys-1"}).get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:configure, panel, {system_id: ""}).get }
  end

  it "configures a device" do
    command_id = exec(:configure, panel, {system_id: "sys-1", event_view: true}).get.not_nil!.as_s

    command = status[command_binding]
    command["id"].should eq command_id
    command["action"].should eq "configure"
    command["config"]["system_id"].should eq "sys-1"
    command["config"]["event_view"].should eq true

    # a different command ID does not complete the command
    exec(:complete, panel, "other").get
    status[command_binding]["id"].should eq command_id

    exec(:complete, panel, command_id).get
    status[command_binding]?.should be_nil

    exec(:remove_stale).get
    device = status[:devices][panel]
    device["config"]["system_id"].should eq "sys-1"
    device["last_command"].should eq command_id
  end

  it "clears a device" do
    command_id = exec(:clear, panel).get.not_nil!.as_s
    command = status[command_binding]
    command["action"].should eq "clear"
    command.as_h.has_key?("config").should be_false

    exec(:complete, panel, command_id).get
    exec(:remove_stale).get
    device = status[:devices][panel]
    device["config"].raw.should be_nil
    device["last_command"].should eq command_id
  end

  it "removes stale devices and commands" do
    exec(:configure, panel, {system_id: "sys-1"}).get
    status[command_binding]?.should_not be_nil

    settings({device_ttl_hours: 0, command_ttl_minutes: 0})
    exec(:remove_stale).get

    status[command_binding]?.should be_nil
    status[:devices].as_h.empty?.should be_true
  end
end
