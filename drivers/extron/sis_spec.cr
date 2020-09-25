require "spec"
require "./sis"

describe Extron::SIS::Command do
  it "forms a Command from arbitrary field types" do
    command = Extron::SIS::Command.new 42, 'a', "foo"
    command.fields[0].should eq(42)
    command.fields[1].should eq('a')
    command.fields[2].should eq("foo")
  end

  it "serialises the command to an IO" do
    command = Extron::SIS::Command.tie 1, 2
    io = IO::Memory.new
    io.write_bytes command
    io.to_s.should eq("1*2!")
  end

  it "provides a string representation suitable for logging" do
    command = Extron::SIS::Command.tie 1, 2
    command.to_s.should eq("‹1*2!›")
  end
end
