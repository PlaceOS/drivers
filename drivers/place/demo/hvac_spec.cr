require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Demo::HVAC" do
  # on_load has published an initial frame
  status[:mode].should eq("cool")
  status[:connected].should eq(true)
  status[:power].should eq(true)
  status[:temperature].as_f.should be_a(Float64)
  status[:occupied].should eq(true)

  # setpoint control + clamping
  exec(:set_temperature, 19.0).get
  status[:setpoint].as_f.should eq(19.0)
  exec(:set_temperature, 99.0).get
  status[:setpoint].as_f.should eq(30.0) # MAX_SETPOINT

  # mode control (string arg deserialises into the Mode enum)
  exec(:set_mode, "heat").get
  status[:mode].should eq("heat")
  exec(:set_mode, "off").get
  status[:mode].should eq("off")
  status[:power].should eq(false)
  status[:heating].should eq(false)
  status[:cooling].should eq(false)

  # fan control
  exec(:set_mode, "cool").get
  exec(:set_fan, "high").get
  status[:fan].should eq("high")
  status[:fan_level].as_i.should eq(3)

  # occupancy setback: emptying the room activates setback and widens the
  # cooling target above the comfort setpoint
  exec(:set_temperature, 21.0).get
  exec(:set_occupied, false).get
  status[:occupied].should eq(false)
  status[:setback_active].should eq(true)

  # re-occupying clears setback
  exec(:set_occupied, true).get
  status[:setback_active].should eq(false)

  # power off then on restores the previous mode
  exec(:set_mode, "heat").get
  exec(:power, false).get
  status[:power].should eq(false)
  status[:mode].should eq("off")
  exec(:power, true).get
  status[:power].should eq(true)
  status[:mode].should eq("heat")
end
