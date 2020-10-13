require "spec"
require "./sis"

include Extron::SIS

describe Command do
  it "forms a Command from arbitrary field types" do
    command = Command.new 42, 'a', "foo"
  end

  it "serialises the command to an IO" do
    command = Command[1, '*', 2, SwitchLayer::All]
    io = IO::Memory.new
    io.write_bytes command
    io.to_s.should eq("1*2!")
  end

  it "provides a string representation suitable for logging" do
    command = Command[1, '*', 2, SwitchLayer::All]
    command.to_s.should eq("‹1*2!›")
  end

  it "flattens nested fields" do
    routes = [
      [1, '*', 2, SwitchLayer::All],
      [3, '*', 4, SwitchLayer::All]
    ]
    command = Command["\e+Q", routes, '\r']
    io = IO::Memory.new
    io.write_bytes command
    io.to_s.should eq("\e+Q1*2!3*4!\r")
  end
end

describe Response do
  describe Response::DeviceError do
    it "parses to a SIS::Error" do
      error = Response::DeviceError.parse "E17"
      error.should eq(Error::Timeout)
    end
  end

  describe Response::Copyright do
    it "parses and provides the full banner" do
      message = "(c) Copyright YYYY, Extron Electronics, Model Name, Vx.xx, nn-nnnn-nn"
      parsed = Response::Copyright.parse message
      parsed.should be_a(String)
      parsed.should eq(message)
    end

    it "does not parse other messages" do
      parsed = Response::Copyright.parse "foo"
      parsed.should be_a(Response::ParseError)
    end
  end

  describe Response::Clock do
    it "parses" do
      clock = "Fri, Feb 13, 2009, 23:31:30"
      parsed = Response::Clock.parse clock
      parsed.as(Time).to_unix.should eq(1234567890)
    end
  end

  describe Response::Tie do
    it "parses" do
      tie = Response::Tie.parse "Out2 In1 All"
      tie.should be_a Tie
      tie = tie.as Tie
      tie.input.should eq(1)
      tie.output.should eq(2)
      tie.layer.should eq(SwitchLayer::All)
    end
  end

  describe Response::Switch do
    it "parses" do
      tie = Response::Switch.parse "In1 All"
      tie.should be_a Switch
      tie = tie.as Switch
      tie.input.should eq(1)
      tie.layer.should eq(SwitchLayer::All)
    end
  end

  describe ".parse" do
    it "builds a parser that includes device errors" do
      resp = Response.parse "Out4 In2 Aud", as: Response::Tie
      typeof(resp).should eq (Tie | Error | Response::ParseError)
    end
  end
end
