require "placeos-driver/spec"

# the core sends this notification as soon as the socket is open
ENGINE_STATUS = {
  "jsonrpc" => "2.0",
  "method"  => "EngineStatus",
  "params"  => {
    "Platform"    => "Core 500i",
    "State"       => "Active",
    "DesignName"  => "SAF‐MainPA",
    "DesignCode"  => "qALFilm6IcAz",
    "IsRedundant" => false,
    "IsEmulator"  => true,
  },
}.to_json + "\0"

LOGON = {
  "User"     => "user",
  "Password" => "pass",
}

DriverSpecs.mock_driver "Qsc::QSysRemote" do
  # ====
  # No credentials are configured, so the greeting is ignored
  transmit ENGINE_STATUS

  exec(:no_op)
  should_send({
    jsonrpc: "2.0",
    method:  "NoOp",
    params:  {} of String => String,
  }.to_json + "\0")

  exec(:get_status)
  should_send({
    jsonrpc: "2.0",
    id:      1,
    method:  "StatusGet",
    params:  0,
  }.to_json + "\0")
  responds({
    "jsonrpc" => "2.0",
    "id"      => 1,
    "result"  => {
      "Platform"    => "Core 500i",
      "State"       => "Active",
      "DesignName"  => "SAF‐MainPA",
      "DesignCode"  => "qALFilm6IcAz",
      "IsRedundant" => false,
      "IsEmulator"  => true,
      "Status"      => {
        "Code"   => 0,
        "String" => "OK",
      },
    },
  }.to_json + "\0")
  status[:platform].should eq("Core 500i")
  status[:state].should eq("Active")
  status[:design_name].should eq("SAF‐MainPA")
  status[:design_code].should eq("qALFilm6IcAz")
  status[:is_redundant].should eq(false)
  status[:is_emulator].should eq(true)
  status[:status].should eq({
    "Code"   => 0,
    "String" => "OK",
  })

  exec(:control_set, "MainGain", 8)
  should_send({
    "jsonrpc" => "2.0",
    "id"      => 2,
    "method"  => "Control.Set",
    "params"  => {
      "Name"  => "MainGain",
      "Value" => 8,
    },
  }.to_json + "\0")
  responds({
    "jsonrpc" => "2.0",
    "id"      => 1234,
    "result"  => [
      {
        "Name"  => "MainGain",
        "Value" => 8,
      },
    ],
  }.to_json + "\0")
  status[:faderMainGain_val].should eq(8)

  exec(:component_get, "My APM", ["ent.xfade.gain", "ent.xfade.gain2"])
  should_send({
    "jsonrpc" => "2.0",
    "id"      => 3,
    "method"  => "Component.Get",
    "params"  => {
      "Name"     => "My APM",
      "Controls" => [
        {"Name" => "ent.xfade.gain"},
        {"Name" => "ent.xfade.gain2"},
      ],
    },
  }.to_json + "\0")
  responds({
    "jsonrpc" => "2.0",
    "result"  => {
      "Name"     => "My APM",
      "Controls" => [
        {
          "Name"     => "ent.xfade.gain",
          "Value"    => -100.0,
          "String"   => "‐100.0dB",
          "Position" => 0,
        },
        {
          "Name"     => "ent.xfade.gain2",
          "Value"    => 8.0,
          "String"   => "8.0dB",
          "Position" => 0.9,
        },
      ],
    },
  }.to_json + "\0")
  status["faderent.xfade.gain_My APM_pos"].should eq(0)
  status["faderent.xfade.gain_My APM"].should eq(0)
  status["faderent.xfade.gain2_My APM_pos"].should eq(0.9)
  status["faderent.xfade.gain2_My APM"].should eq(90.0)

  exec(:change_group_add_controls, "my change group", ["some control", "another control"])
  should_send({
    "jsonrpc" => "2.0",
    "id"      => 4,
    "method"  => "ChangeGroup.AddControl",
    "params"  => {
      "Id"       => "my change group",
      "Controls" => ["some control", "another control"],
    },
  }.to_json + "\0")
  responds({
    "jsonrpc" => "2.0",
    "id"      => 4,
    "result"  => {
      "Id"      => "my change group",
      "Changes" => [
        {
          "Name"   => "some control",
          "Value"  => -12,
          "String" => "‐12dB",
        },
        {
          "Name"   => "another control",
          "Value"  => -6,
          "String" => "‐6dB",
        },
      ],
    },
  }.to_json + "\0")

  # ====
  # Credentials applied while connected log on immediately
  puts "\nLOGON:\n=============="

  settings({
    username: "user",
    password: "pass",
  })

  should_send({
    jsonrpc: "2.0",
    id:      5,
    method:  "Logon",
    params:  LOGON,
  }.to_json + "\0")

  # the response to a logon must not trigger another logon
  responds({
    "jsonrpc" => "2.0",
    "id"      => 5,
    "result"  => true,
  }.to_json + "\0")

  # ====
  # A `Logon required` error logs in, then retries the failed request
  puts "\nLOGON REQUIRED:\n=============="

  exec(:control_set, "MainGain", 10)
  request = {
    "jsonrpc" => "2.0",
    "id"      => 6,
    "method"  => "Control.Set",
    "params"  => {
      "Name"  => "MainGain",
      "Value" => 10,
    },
  }.to_json + "\0"
  should_send request

  responds({
    "jsonrpc" => "2.0",
    "id"      => 6,
    "error"   => {
      "code"    => 10,
      "message" => "Logon required",
    },
  }.to_json + "\0")

  should_send({
    jsonrpc: "2.0",
    id:      7,
    method:  "Logon",
    params:  LOGON,
  }.to_json + "\0")
  responds({
    "jsonrpc" => "2.0",
    "id"      => 7,
    "result"  => true,
  }.to_json + "\0")

  # the original request is re-sent, unchanged
  should_send request
  responds({
    "jsonrpc" => "2.0",
    "id"      => 6,
    "result"  => [
      {
        "Name"  => "MainGain",
        "Value" => 10,
      },
    ],
  }.to_json + "\0")
  status[:faderMainGain_val].should eq(10)

  # NOTE:: on a real core the greeting is what triggers the logon, as
  # credentials are in settings before the connection is established. That
  # can't be exercised here, `@authenticated` is only cleared on disconnect
  # and a spec can't drop the connection of a driver that isn't makebreak
end
