class Display < DriverSpecs::MockDriver
  def on_load
    self[:power] = false
  end

  def power(state : Bool)
    self[:power] = state
  end
end

class Switcher < DriverSpecs::MockDriver
end

DriverSpecs.mock_driver "Place::LogicExample" do
  system({
    Display:  {Display, Display},
    Switcher: {Switcher},
  })

  exec(:power_state?).get.should eq(false)

  # Updating emulated module state
  system(:Display_1)[:power] = "true"
  exec(:power_state?).get.should eq(true)

  # Expecting a function call
  exec(:power, false)
  exec(:power_state?).get.should eq(false)

  # Expecting a function call to return a result
  exec(:power, true).get.should eq(true)
end
