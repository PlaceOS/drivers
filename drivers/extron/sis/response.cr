require "pars"

# Parsers for responses and asynchronous messages originating from Extron SIS
# devices.
module Extron::SIS::Response
  include Pars

  # Parses a response packet with specified *parser*.
  #
  # Returns the parser output, a parse error or a device error.
  def self.parse(data : String, as parser : Parser(T)) forall T
    (parser | DeviceError | "unhandled device response").parse data
  end

  # :ditto:
  def self.parse(data : Bytes, as parser : Parser(T)) forall T
    parse String.new(data), parser
  end

  # :nodoc:
  Delimiter = Parse.string SIS::DELIMITER

  # Parse a full command response as a String. Delimiter is optional as it may
  # have already been dropped by an upstream tokenizer.
  Raw = ((Parse.char ^ Delimiter) * (0..) << Delimiter * (0..1)).map &.join

  # Error codes returned from the device.
  DeviceError = Parse.char('E') >> Parse.integer.map { |e| SIS::Error.new e.to_i }

  # Copyright message shown on connect.
  Copyright = (Parse.string("(c) Copyright") + Raw).map &.join

  # Part of the copyright banner, but appears on a new line so will tokenize as
  # as standalone message.
  Clock = Raw.map { |date| Time.parse_utc date, "%a, %b %d, %Y, %T" }

  # Quick response, occurs following quick tie, or siwtching interaction from
  # the device's front panel.
  Qik = Parse.string("Qik") >> Parse.const(Ok.new)

  # Signal route update.
  Tie = Parse.do({
    output <= Parse.string("Out") >> Parse.integer.map &->Output.new(String),
    _ <= Parse.char(' '),
    input <= Parse.string("In") >> Parse.integer.map &->Input.new(String),
    _ <= Parse.char(' '),
    layer <= Parse.word.map &->SwitchLayer.parse(String),
    Parse.const SIS::Tie.new input, output, layer
  })

  # Parses for device messages that can be safely ignored - these exist mainly
  # to flush initial connect banners
  Ignorable = (Copyright | Clock) >> Parse.const(Ok.new)

  # Async messages that can be expected outside of a command -> response flow.
  Unsolicited = DeviceError | Tie | Ignorable
end
