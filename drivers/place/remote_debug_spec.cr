require "placeos-driver/spec"
require "./remote_debug_models"

DriverSpecs.mock_driver "Place::RemoteDebug" do
  device_id = "DEV-TEST00000001"
  device = {
    id:         device_id,
    app:        "control",
    version:    "1.0.0",
    build:      "abc",
    url:        "https://placeos.test/control/",
    user_agent: "Test",
    started_at: 1000,
  }
  entry = ->(seq : Int32) do
    {seq: seq, timestamp: seq, level: "info", source: "console", message: "line #{seq}"}
  end

  it "should set, change and clear the log request of a device" do
    id = exec(:request_logs, device_id, "info", {history: 50}).get.not_nil!.as_s
    status["device:#{device_id}"].should eq JSON.parse({
      logs:     {id: id, level: "info", history: 50},
      commands: [] of String,
    }.to_json)

    exec(:set_level, device_id, "debug").get
    status["device:#{device_id}"]["logs"]["id"].should eq id
    status["device:#{device_id}"]["logs"]["level"].should eq "debug"

    exec(:stop_logs, device_id).get
    status["device:#{device_id}"]?.should be_nil
  end

  it "should clear the log request when the duration ends" do
    exec(:request_logs, device_id, "warn", {duration: 100}).get
    status["device:#{device_id}"]["logs"]["level"].should eq "warn"

    sleep 300.milliseconds
    status["device:#{device_id}"]?.should be_nil
  end

  it "should keep posted entries once each and start again after a reload" do
    id = exec(:request_logs, device_id, "info").get.not_nil!.as_s
    exec(:post_logs, device_id, "old-request", [entry.call(9)], device).get
    status["logs:#{device_id}"]?.should be_nil

    exec(:post_logs, device_id, id, [entry.call(3), entry.call(2)], device).get
    exec(:post_logs, device_id, id, [entry.call(3), entry.call(4)], device).get
    # Only the user that first called for the device ID can add entries
    exec(:post_logs, device_id, id, [entry.call(5)], device, user_id: "user-2").get
    status["logs:#{device_id}"]["entries"].as_a.map(&.["seq"].as_i).should eq [2, 3, 4]

    # A request for older entries adds them before the entries that the driver has
    id = exec(:request_logs, device_id, "info", {before: 2}).get.not_nil!.as_s
    status["device:#{device_id}"]["logs"]["before"].should eq 2
    exec(:post_logs, device_id, id, [entry.call(1)], device).get
    status["logs:#{device_id}"]["entries"].as_a.map(&.["seq"].as_i).should eq [1, 2, 3, 4]

    reloaded = device.merge(started_at: 2000)
    exec(:post_logs, device_id, id, [entry.call(1)], reloaded).get
    status["logs:#{device_id}"].should eq JSON.parse({device: reloaded, entries: [entry.call(1)]}.to_json)
    status["devices"][device_id]["started_at"].should eq 2000
    status["devices"][device_id]["last_seen"].as_i64.should be > 0

    # A late batch from the app session before the reload does not replace the new entries
    exec(:post_logs, device_id, id, [entry.call(5)], device).get
    status["logs:#{device_id}"]["entries"].as_a.map(&.["seq"].as_i).should eq [1]

    exec(:stop_logs, device_id).get
  end

  it "should keep the log request when it adds a command, and keep the result" do
    request_id = exec(:request_logs, device_id, "info").get.not_nil!.as_s
    command_id = exec(:send_command, device_id, "settings", {keys: ["app.title"]}).get.not_nil!.as_s
    status["device:#{device_id}"]["logs"]["id"].should eq request_id
    status["device:#{device_id}"]["commands"].should eq JSON.parse([{id: command_id, type: "settings", keys: ["app.title"]}].to_json)

    result = {ok: true, data: {"app.title" => "Panel"}}
    exec(:command_result, device_id, command_id, result, device, user_id: "user-2").get
    status["device:#{device_id}"]["commands"].as_a.size.should eq 1

    exec(:command_result, device_id, command_id, result, device).get
    status["device:#{device_id}"]["commands"].as_a.should be_empty

    results = Array(Place::RemoteDebugCommandResult).from_json(status["results:#{device_id}"].to_json)
    results.size.should eq 1
    results[0].id.should eq command_id
    results[0].type.should eq Place::RemoteDebugCommandType::Settings
    results[0].result.data.should eq JSON.parse(%({"app.title": "Panel"}))

    exec(:stop_logs, device_id).get
    status["device:#{device_id}"]?.should be_nil
  end

  it "should replace a result that is too large with an error" do
    command_id = exec(:send_command, device_id, "status").get.not_nil!.as_s
    exec(:command_result, device_id, command_id, {ok: true, data: "x" * 100_001}, device).get

    last = status["results:#{device_id}"].as_a.last
    last["id"].should eq command_id
    last["result"].should eq JSON.parse(%({"ok": false, "error": "Result is too large"}))
  end

  it "should list a device that registers" do
    fixed = device.merge(id: "DEV-FIXED0001", app: "signage")
    exec(:register, fixed).get
    status["devices"]["DEV-FIXED0001"]["app"].should eq "signage"
    status["devices"]["DEV-FIXED0001"]["last_seen"].as_i64.should be > 0

    exec(:register, fixed.merge(id: "not a device id")).get
    status["devices"]["not a device id"]?.should be_nil

    # Only the user that first called for the device ID can change it
    exec(:register, fixed.merge(app: "other"), user_id: "user-2").get
    status["devices"]["DEV-FIXED0001"]["app"].should eq "signage"
  end

  it "should not add commands that are not valid" do
    expect_raises(Exception) { exec(:send_command, device_id, "navigate", {path: "x"}).get }
    expect_raises(Exception) { exec(:send_command, device_id, "run_script").get }
    expect_raises(Exception) { exec(:send_command, "not a device id", "status").get }
    status["device:#{device_id}"]?.should be_nil

    command_id = exec(:send_command, device_id, "clear_cache").get.not_nil!.as_s
    status["device:#{device_id}"]["commands"].should eq JSON.parse([{id: command_id, type: "clear_cache"}].to_json)

    # The admin views show that the list is full when the result is `null`
    19.times { exec(:send_command, device_id, "status").get.not_nil!.as_s }
    exec(:send_command, device_id, "status").get.try(&.raw).should be_nil
  end
end
