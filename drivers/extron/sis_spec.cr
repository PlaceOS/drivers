require "spec"
require "./sis"

include Extron::SIS

describe Command do
  it "forms a Command from arbitrary field types" do
    Command.new 42, 'a', "foo"
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
      [3, '*', 4, SwitchLayer::All],
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
      clock = "Fri, 13 Feb 2009 23:31:30"
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

  describe Response::SwitcherInformation do
    it "parses" do
      info = Response::SwitcherInformation.parse "V1X2 A3X4"
      info.should be_a SwitcherInformation
      info = info.as SwitcherInformation
      info.video.inputs.should eq 1
      info.video.outputs.should eq 2
      info.audio.inputs.should eq 3
      info.audio.outputs.should eq 4
    end
  end

  describe Response::GroupVolume do
    it "parses" do
      vol = Response::GroupVolume.parse "GrpmD1*-500"
      if vol.is_a? Response::ParseError
        fail "parse error: #{vol}"
      else
        level, group = vol
        level.should eq -500
        group.should eq 1
      end
    end
  end

  describe ".parse" do
    it "builds a parser that includes device errors" do
      resp = Response.parse "Out4 In2 Aud", as: Response::Tie
      typeof(resp).should eq (Tie | Error | Response::ParseError)
    end

    it "fails for unhandled responses" do
      resp = Response.parse "not a real response", as: Response::Switch
      resp.should be_a(Response::ParseError)
      resp.as(Response::ParseError).message.should eq("unhandled device response")
    end
  end
end
