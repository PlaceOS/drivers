require "spec"
require "./sis"

describe Extron::SIS::Command do
  it "forms a Command from arbitrary field types" do
    command = Extron::SIS::Command.new 42, 'a', "foo"
  end

  it "serialises the command to an IO" do
    command = Extron::SIS::Command[1, '*', 2, Extron::SIS::SwitchLayer::All]
    io = IO::Memory.new
    io.write_bytes command
    io.to_s.should eq("1*2!")
  end

  it "provides a string representation suitable for logging" do
    command = Extron::SIS::Command[1, '*', 2, Extron::SIS::SwitchLayer::All]
    command.to_s.should eq("‹1*2!›")
  end

  it "flattens nested fields" do
    routes = [
      [1, '*', 2, Extron::SIS::SwitchLayer::All],
      [3, '*', 4, Extron::SIS::SwitchLayer::All]
    ]
    command = Extron::SIS::Command["\e+Q", routes, '\r']
    io = IO::Memory.new
    io.write_bytes command
    io.to_s.should eq("\e+Q1*2!3*4!\r")
  end
end

describe Extron::SIS::Response do
  describe Extron::SIS::Response::DeviceError do
    it "parses to a SIS::Error" do
      error = Extron::SIS::Response::DeviceError.parse "E17"
      error.should eq(Extron::SIS::Error::Timeout)
    end
  end

  describe Extron::SIS::Response::Tie do
    it "parses" do
      tie = Extron::SIS::Response::Tie.parse "Out2 In1 All"
      tie.should be_a Extron::SIS::Tie
      tie = tie.as Extron::SIS::Tie
      tie.input.should eq(1)
      tie.output.should eq(2)
      tie.layer.should eq(Extron::SIS::SwitchLayer::All)
    end
  end
end
