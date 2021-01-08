DriverSpecs.mock_driver "Qsc::QSysRemote" do
  settings({
    username: "user",
    password: "pass"
  })

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
    id: 1,
    jsonrpc: "2.0",
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

  # exec(:fader, "1", 1, "component")
end
