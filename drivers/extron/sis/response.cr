require "pars3k"

# Parsers for responses and asynchronous messages originating from Extron SIS
# devices.
module Extron::SIS::Response
  include Pars3k

  # Parses a response packet with specified *expected* parser.
  #
  # Returns the parser output, a parse error or a device error.
  def self.parse(data : Bytes, as expected : T) forall T
    (expected / DeviceError).parse String.new(data)
  end

  # :nodoc:
  def self.rest_of_buffer(full = true)
    Parser(String).new do |ctx|
      result = full ? ctx.parsing : ctx.parsing[ctx.position..-1]
      ParseResult(String).new result, ctx.next
    end
  end

  # Error codes returned from the device.
  DeviceError = Parse.char('E') >> Parse.int.transform { |e| SIS::Error.new e }

  # Copyright message shown on connect.
  Copyright = Parse.string("(c) Copyright") + rest_of_buffer

  # Part of the copyright banner, but appears on a new line so will tokenize as
  # as standalone message.
  Clock = rest_of_buffer.transform { |date| Time.parse_utc date, "%a, %b %d, %Y, %T" }

  # Signal route update.
  Tie = do_parse({
    output <= (Parse.string("Out") >> Parse.int.transform &->Output.new(Int32)),
    _ <= Parse.char(' '),
    input <= (Parse.string("In") >> Parse.int.transform &->Input.new(Int32)),
    _ <= Parse.char(' '),
    layer <= Parse.word.transform &->SwitchLayer.parse(String),
    Parse.constant SIS::Tie.new input, output, layer
  })

  # Parses for device messages that can be safely ignored - these exist mainly
  # to flush initial connect banners
  Ignorable = (Copyright / Clock).transform { |x| Ignored.new x }
  alias Ignored = Box

  # Async messages that can be expected outside of a command -> response flow.
  Unsolicited = DeviceError / Tie / Ignorable
end
