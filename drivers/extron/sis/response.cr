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

  # Error codes returned from the device
  DeviceError = Parse.char('E') >> Parse.int.transform { |e| SIS::Error.new e }

  #Copyright = do_parse

  # Signal route update
  Tie = do_parse({
    output <= (Parse.string("Out") >> Parse.int.transform &->Output.new(Int32)),
    _ <= Parse.char(' '),
    input <= (Parse.string("In") >> Parse.int.transform &->Input.new(Int32)),
    _ <= Parse.char(' '),
    layer <= Parse.word.transform &->SwitchLayer.parse(String),
    Parse.constant SIS::Tie.new input, output, layer
  })

  # Async messages that can be expected outside of a command -> response flow.
  Unsolitcited = DeviceError / Tie
end
