require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::RemoteSetup" do
  panel = "DEV-3F9A0C12B7E4"
  command_binding = "device_#{panel}"

  it "registers devices" do
    status[:connected].should eq true
    status[:devices].as_h.empty?.should be_true
    status[:clear_list].as_a.empty?.should be_true
    status[:clear_systems].as_a.empty?.should be_true

    exec(:register, panel, "booking-panel").get
    # `remove_stale` publishes the devices without waiting for the interval
    exec(:remove_stale).get

    device = status[:devices][panel]
    device["id"].should eq panel
    device["app"].should eq "booking-panel"
    device.as_h.has_key?("config").should be_true
    device["config"].raw.should be_nil
  end

  it "rejects bad input" do
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:register, "", "control").get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:register, "DEV-1", "phone").get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:configure, "", {system_id: "sys-1"}).get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:configure, panel, {system_id: ""}).get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:clear_system, "signage", "").get }
  end

  it "configures a device" do
    command_id = exec(:configure, panel, {system_id: "sys-1", event_view: true}).get.not_nil!.as_s

    command = status[command_binding]
    command["id"].should eq command_id
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

  it "configures a device that did not register" do
    control = "DEV-0A1B2C3D4E5F"
    command_id = exec(:configure, control, {system_id: "sys-2"}).get.not_nil!.as_s
    status["device_#{control}"]["id"].should eq command_id

    # the device is set up, so it completes the command with its app
    exec(:complete, control, command_id, "control").get
    status["device_#{control}"]?.should be_nil

    exec(:remove_stale).get
    device = status[:devices][control]
    device["app"].should eq "control"
    device["config"]["system_id"].should eq "sys-2"
    device["last_command"].should eq command_id
  end

  it "clears a device until it registers" do
    # a device that is set up does not have to be in `devices`
    exec(:clear, "DEV-NOT-LISTED").get
    exec(:clear, panel).get
    status[:clear_list].should eq ["DEV-NOT-LISTED", panel]

    # the device clears, shows its setup screen and registers
    exec(:register, panel, "booking-panel").get
    status[:clear_list].should eq ["DEV-NOT-LISTED"]

    exec(:remove_stale).get
    status[:devices][panel]["config"].raw.should be_nil
  end

  it "clears the devices of a system" do
    exec(:clear_system, "signage", "sys-display").get

    entry = status[:clear_systems][0]
    entry["id"].as_s.empty?.should be_false
    entry["app"].should eq "signage"
    entry["system_id"].should eq "sys-display"
  end

  it "removes stale devices, commands and clears" do
    exec(:configure, panel, {system_id: "sys-1"}).get
    status[command_binding]?.should_not be_nil

    settings({device_ttl_hours: 0, command_ttl_minutes: 0})
    exec(:remove_stale).get

    status[command_binding]?.should be_nil
    status[:devices].as_h.empty?.should be_true
    status[:clear_list].as_a.empty?.should be_true
    status[:clear_systems].as_a.empty?.should be_true
  end
end
