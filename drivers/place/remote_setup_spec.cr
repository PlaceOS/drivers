require "placeos-driver/spec"

# Run the block until it is true, for 3 seconds maximum, then expect true.
# The driver publishes `devices` changes once per second.
macro wait_until(&block)
  %done = false
  30.times do
    %done = begin
      {{block.body}}
    end
    break if %done
    sleep 100.milliseconds
  end
  %done.should be_true
end

DriverSpecs.mock_driver "Place::RemoteSetup" do
  panel = "DEV-3F9A0C12B7E4"
  command_binding = "device_#{panel}"

  it "registers devices" do
    # the driver manager sets `connected` after `on_load`
    wait_until { status[:connected]? == true }
    status[:devices].as_h.empty?.should be_true
    status[:clear_list].as_a.empty?.should be_true
    status[:clear_systems].as_a.empty?.should be_true
    status[:show_ids].as_a.empty?.should be_true

    before = Time.utc.to_unix_ms
    exec(:register, panel, "booking-panel").get
    wait_until { !status[:devices][panel]?.nil? }

    device = status[:devices][panel]
    device["id"].should eq panel
    device["app"].should eq "booking-panel"
    device.as_h.has_key?("config").should be_true
    device["config"].raw.should be_nil
    (before..Time.utc.to_unix_ms).includes?(device["last_seen"].as_i64).should be_true
  end

  it "publishes heartbeats with the minute task" do
    last_seen = status[:devices][panel]["last_seen"].as_i64
    sleep 10.milliseconds
    exec(:register, panel, "booking-panel").get

    # the one-second task does not publish a heartbeat on its own
    sleep 1.5.seconds
    status[:devices][panel]["last_seen"].as_i64.should eq last_seen

    exec(:remove_stale).get
    wait_until { status[:devices][panel]["last_seen"].as_i64 > last_seen }
  end

  it "rejects bad input" do
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:register, "", "control").get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:register, "DEV-1", "phone").get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:configure, "", {system_id: "sys-1"}).get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:configure, panel, {system_id: ""}).get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:clear_system, "signage", "").get }
    expect_raises(PlaceOS::Driver::RemoteException) { exec(:show_device_ids, "signage", "").get }
  end

  it "configures a device" do
    first_id = exec(:configure, panel, {system_id: "sys-0"}).get.not_nil!.as_s
    command_id = exec(:configure, panel, {system_id: "sys-1", event_view: true}).get.not_nil!.as_s
    command_id.should_not eq first_id

    command = status[command_binding]
    command["id"].should eq command_id
    command["config"]["system_id"].should eq "sys-1"
    command["config"]["event_view"].should eq true

    # the replaced command does not complete the new command
    exec(:complete, panel, first_id).get
    status[command_binding]["id"].should eq command_id

    exec(:complete, panel, command_id).get
    status[command_binding]?.should be_nil
    wait_until { status[:devices][panel]["last_command"]? == command_id }
    status[:devices][panel]["config"]["system_id"].should eq "sys-1"
  end

  it "configures a device that did not register" do
    control = "DEV-0A1B2C3D4E5F"
    command_id = exec(:configure, control, {system_id: "sys-2"}).get.not_nil!.as_s
    status["device_#{control}"]["id"].should eq command_id

    # the device is set up, so it completes the command with its app
    exec(:complete, control, command_id, "control").get
    status["device_#{control}"]?.should be_nil

    wait_until { !status[:devices][control]?.nil? }
    device = status[:devices][control]
    device["app"].should eq "control"
    device["config"]["system_id"].should eq "sys-2"
    device["last_command"].should eq command_id
  end

  it "clears a device until it registers" do
    # a device that is set up does not have to be in `devices`
    exec(:clear, "DEV-NOT-LISTED").get
    exec(:clear, panel).get
    # published at once, so the flow sees the ID before the device registers
    status[:clear_list].should eq ["DEV-NOT-LISTED", panel]

    # the device clears, shows its setup screen and registers
    exec(:register, panel, "booking-panel").get
    wait_until { status[:clear_list] == ["DEV-NOT-LISTED"] }
    wait_until { status[:devices][panel]["config"].raw.nil? }
  end

  it "clears the devices of a system" do
    exec(:clear_system, "signage", "sys-display").get

    entry = status[:clear_systems][0]
    entry["id"].as_s.empty?.should be_false
    entry["app"].should eq "signage"
    entry["system_id"].should eq "sys-display"
  end

  it "asks devices to show their ID" do
    exec(:show_device_ids, "signage", "sys-display", 120).get
    exec(:show_device_ids).get

    targeted, everyone = status[:show_ids].as_a
    targeted["id"].as_s.empty?.should be_false
    targeted["app"].should eq "signage"
    targeted["system_id"].should eq "sys-display"
    (targeted["expires_at"].as_i64 - targeted["issued_at"].as_i64).should eq 120_000

    # without filters, all devices show their ID, for 60 seconds by default
    everyone.as_h.has_key?("app").should be_false
    everyone.as_h.has_key?("system_id").should be_false
    (everyone["expires_at"].as_i64 - everyone["issued_at"].as_i64).should eq 60_000
  end

  it "removes expired show ID requests" do
    exec(:show_device_ids, "control", "sys-long", 120).get
    exec(:show_device_ids, "control", "sys-short", 1).get
    targets = ->(entries : Array(JSON::Any)) { entries.map(&.["system_id"]?) }
    targets.call(status[:show_ids].as_a).includes?("sys-short").should be_true

    wait_until do
      exec(:remove_stale).get
      !targets.call(status[:show_ids].as_a).includes?("sys-short")
    end
    targets.call(status[:show_ids].as_a).includes?("sys-long").should be_true
  end

  it "keeps the devices that were seen last" do
    1000.times { |index| exec(:register, "DEV-LIMIT-#{index}", "signage").get }
    # a heartbeat makes the first device the last seen
    sleep 10.milliseconds
    exec(:register, "DEV-LIMIT-0", "signage").get
    exec(:register, "DEV-LIMIT-1000", "signage").get

    wait_until { !status[:devices]["DEV-LIMIT-1000"]?.nil? }
    devices = status[:devices].as_h
    devices.size.should eq 1000
    # DEV-LIMIT-1 was seen first
    devices.has_key?("DEV-LIMIT-0").should be_true
    devices.has_key?("DEV-LIMIT-1").should be_false
  end

  it "removes stale devices, commands and clears" do
    stale = "DEV-STALE"
    exec(:register, stale, "control").get
    exec(:configure, panel, {system_id: "sys-1"}).get
    exec(:clear, panel).get
    exec(:clear_system, "control", "sys-kept").get
    wait_until { !status[:devices][stale]?.nil? }

    settings({device_ttl_hours: 0, command_ttl_minutes: 0})
    # the settings update can arrive after the next call
    wait_until do
      exec(:remove_stale).get
      status[command_binding]?.nil?
    end

    wait_until { status[:devices].as_h.empty? && status[:clear_list].as_a.empty? }
    # `clear_systems` entries stay for 15 minutes, whatever the command time.
    # A new entry publishes the whole list, so this reads the list after cleanup.
    exec(:clear_system, "control", "sys-marker").get
    systems = status[:clear_systems].as_a.map(&.["system_id"])
    systems.includes?("sys-marker").should be_true
    systems.includes?("sys-kept").should be_true
  end
end
