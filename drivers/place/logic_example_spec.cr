
EngineSpec.mock_driver "Place::LogicExample" do
  system({
    Display: [{
      # current state
      power: true,

      # function definitions
      "$power": {state: {"Bool"}}
    }]
  })
  exec(:power_state?).get.should eq(true)

  # Updating emulated module state
  system(:Display_1)[:power] = "false"
  exec(:power_state?).get.should eq(false)

  # Expecting a function call
  # TODO:: expect(:Display_1, :power) { |arguments| system(:Display_1)[:power] = arguments["state"].to_json }
  exec(:power, true)
  exec(:power_state?).get.should eq(true)
end
