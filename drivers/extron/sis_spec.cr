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
    routes = [Extron::SIS::Route.new(1, 2), Extron::SIS::Route.new(3, 4)]
    command = Extron::SIS::Command["\e+Q", routes, '\r']
    io = IO::Memory.new
    io.write_bytes command
    io.to_s.should eq("\e+Q1*2!3*4!\r")
  end
end
