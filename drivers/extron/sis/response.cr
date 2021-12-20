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

  # Parses a number from the input into *type*.
  private def self.num(type : T.class) forall T
    Parse.integer.map &->T.new(String)
  end

  # Parses a word from the input into an enum of *type*.
  private def self.word_as_enum(type : T.class) forall T
    Parse.word.map &->T.parse(String)
  end

  # :nodoc:
  BoolField = Parse.char('0') >> Parse.const(false) | Parse.char('1') >> Parse.const(true)

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
  Clock = Raw.map { |date| Time.parse_utc date, "%a, %d %b %Y %T" }

  # Quick response, occurs following quick tie, or switching interaction from
  # the device's front panel.
  Qik = Parse.string("Qik") >> Parse.const(Ok.new)

  # Matrix signal route update.
  Tie = Parse.do({
    output <= Parse.string("Out") >> num(Output),
    _ <= Parse.char(' '),
    input <= Parse.string("In") >> num(Input),
    _ <= Parse.char(' '),
    layer <= word_as_enum(MatrixLayer),
    Parse.const SIS::Tie.new input, output, layer,
  })

  # Broadcast or single output route update.
  Switch = Parse.do({
    input <= Parse.string("In") >> num(Input),
    _ <= Parse.char(' '),
    layer <= word_as_enum(MatrixLayer),
    Parse.const SIS::Switch.new input, layer,
  })

  # Group volume update / response. Level are provided in the raw device range
  # of -1000..0.
  GroupVolume = Parse.do({
    _ <= Parse.string("GrpmD"),
    group <= num(Int32),
    _ <= Parse.char('*'),
    _ <= Parse.char('-'),
    level <= num(Int32).map { |val| val * -1 },
    Parse.const({level, group}),
  })

  # Group audio mute update / response. Level are provided in the raw device range
  # of -1000..0.
  GroupMute = Parse.do({
    _ <= Parse.string("GrpmD"),
    group <= num(Int32),
    _ <= Parse.char('*'),
    state <= BoolField,
    Parse.const({state, group}),
  })

  MatrixSize = Parse.do({
    inputs <= num(Input),
    _ <= Parse.char('X'),
    outputs <= num(Output),
    Parse.const SIS::MatrixSize.new inputs, outputs,
  })

  SwitcherInformation = Parse.do({
    _ <= Parse.char('V'),
    video <= MatrixSize,
    _ <= Parse.char(' '),
    _ <= Parse.char('A'),
    audio <= MatrixSize,
    Parse.const SIS::SwitcherInformation.new video, audio,
  })

  Empty = Parse.string("\r\n") >> Parse.const(nil)

  # Async messages that can be expected outside of a command -> response flow.
  Unsolicited = DeviceError | Tie | Copyright | Clock | Empty
end
