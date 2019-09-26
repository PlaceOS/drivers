require "./spec_helper"
require "../src/protocols/telnet"

describe Protocols::Telnet do
  it "should buffer input and process any telnet commands" do
    log = [] of Bytes
    telnet = Protocols::Telnet.new do |cmd|
      # Write callback
      log << cmd
    end
    log << telnet.buffer("\xFF\xFD\x18\xFF\xFD \xFF\xFD#\xFF\xFD'hello there")
    log.should eq(["\xFF\xFC\x18", "\xFF\xFC ", "\xFF\xFC#", "\xFF\xFC'", "hello there"].map(&.to_slice))
  end

  it "should append the appropriate line endings to requests" do
    telnet = Protocols::Telnet.new { |cmd| }
    telnet.buffer("\xFF\xFB\x03")
    telnet.prepare("hello").should eq("hello\r\0".to_slice)
  end
end
