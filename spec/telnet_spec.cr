require "./spec_helper"
require "../src/protocols/telnet"

describe Protocols::Telnet do
  it "should buffer input and process any telnet commands" do
    log = [] of Bytes
    telnet = Protocols::Telnet.new do |cmd|
      # Write callback
      log << cmd
    end

    # test combined stream
    log << telnet.buffer("\xFF\xFD\x18\xFF\xFD \xFF\xFD#\xFF\xFD'hello there")
    log.should eq(["\xFF\xFC\x18", "\xFF\xFC ", "\xFF\xFC#", "\xFF\xFC'", "hello there"].map(&.to_slice))
    log.clear

    # test split streams, partial content should be buffered
    log << telnet.buffer("\xFF\xFD\x18\xFF")
    log.should eq ["\xFF\xFC\x18", ""].map(&.to_slice)
    log.clear

    log << telnet.buffer("\xFD \xFF\xFD")
    log.should eq ["\xFF\xFC ", ""].map(&.to_slice)
    log.clear

    log << telnet.buffer("#\xFF\xFD'hello there")
    log.should eq(["\xFF\xFC#", "\xFF\xFC'", "hello there"].map(&.to_slice))
    log.clear

    # test ignoring sub negotiation
    log << telnet.buffer("\xFF\xFD\x18\xFF\xFAsubnegotiation\xFF")
    telnet.buffer.should eq "\xFF\xFAsubnegotiation\xFF".to_slice
    log.should eq ["\xFF\xFC\x18", ""].map(&.to_slice)
    log.clear

    log << telnet.buffer("\xFFsubnegotiation")
    log.should eq [""].map(&.to_slice)
    log.clear

    log << telnet.buffer("test\xFF\xF0hello there")
    log.should eq ["hello there"].map(&.to_slice)
    log.clear
  end

  it "should append the appropriate line endings to requests" do
    telnet = Protocols::Telnet.new { |cmd| }
    telnet.buffer("\xFF\xFB\x03")
    telnet.prepare("hello").should eq("hello\r\0".to_slice)

    # Check that requests are escaped properly
    telnet.prepare("hello\xFFthere", escape: true).should eq("hello\xFF\xFFthere\r\0".to_slice)
  end
end
