DriverSpecs.mock_driver "Qsc::QSysRemote" do
  settings({
    username: "user",
    password: "pass"
  })

  # logon
  should_send({
    jsonrpc: "2.0",
    method: "Logon",
    params: {
      User: "user",
      Password: "pass"
    }
  }.to_json + "\0")
  responds({"TODO" => "TODO"}.to_json + "\0")

  exec(:no_op)
  should_send({
    jsonrpc: "2.0",
    method: "NoOp",
    params: {} of String => String
  }.to_json + "\0")
  responds({"TODO" => "TODO"}.to_json + "\0")

  exec(:get_status)
  should_send({
    jsonrpc: "2.0",
    id: 1,
    method: "StatusGet",
    params: 0
  }.to_json + "\0")
  responds({
    "jsonrpc" => "2.0",
    "id" => 1,
    "result" => {
      "Platform" => "Core 500i",
      "State" => "Active",
      "DesignName" => "SAF‐MainPA",
      "DesignCode" => "qALFilm6IcAz",
      "IsRedundant" => false,
      "IsEmulator" => true,
      "Status" => {
        "Code" => 0,
        "String" => "OK"
      }
    }
  }.to_json + "\0")
  status[:platform].should eq("Core 500i")
  status[:state].should eq("Active")
  status[:design_name].should eq("SAF‐MainPA")
  status[:design_code].should eq("qALFilm6IcAz")
  status[:is_redundant].should eq(false)
  status[:is_emulator].should eq(true)
  status[:status].should eq({
    "Code" => 0,
    "String" => "OK"
  })

  exec(:control_set, "MainGain", -12)
  should_send({
    "jsonrpc" => "2.0",
    "id" => 2,
    "method" => "Control.Set",
    "params" => {
       "Name" => "MainGain",
       "Value" => -12
    }
  }.to_json + "\0")
  responds({
    "jsonrpc" => "2.0",
    "id" => 1234,
    "result" => [
       {
        "Name" => "MainGain",
        "Value" => -12
       }
    ]
  }.to_json + "\0")
  status[:faderMainGain].should eq(-12)

  # exec(:fader, "1", 1, "component")
end
