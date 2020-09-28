# Implementation, types and utilities for working with the Extron Simple
# Instruction Set (SIS) device control protocol.
#
# This protocol is used for control of all Extron signal distribution,
# processing and general audio-visual products via SSH, telnet and serial
# control.
module Extron::SIS
  TELNET_PORT = 21
  SSH_PORT = 22023

  DELIMITER = "\r\n"

  # Illegal characters for use in property names.
  SPECIAL_CHARS = "+-,@=‘[]{}<>`“;:|\?".chars

  # Device error numbers
  enum Errno
    InvalidInput = 1
    InvalidCommand = 10
    InvalidPresent = 11
    InvalidOutput = 12
    InvalidParameter = 13
    InvalidForConfig = 14
    Timeout = 17
    Busy = 22
    PrivilegesViolation = 24
    DeviceNotPresent = 25
    MaxConnectionsExceeded = 26
    InvalidEventNumber = 27
    FileNotFound = 28
  end

  alias Input = UInt8

  alias Output = UInt8

  # Layers for targetting signal distribution operations.
  enum SwitchLayer : UInt8
    All = 0x21 # '!'
    Aud = 0x24 # '$'
    Vid = 0x25 # '%'
    RBG = 0x26 # '&'
    def to_s(io : IO)
      io.write_byte value
    end
  end

  # Struct for representing a signal path.
  record Route, input : Input, output : Output, layer = SwitchLayer::All do
    def to_s(io : IO)
      io << input
      io << '*'
      io << output
      io << layer
    end
  end

  # Structure for representing a SIS device command.
  #
  # Commands are composed from a set of *fields*. The contents and types of these
  # are arbitrary, however they must be capable of serialising to an IO.
  struct Command(*T)
    def initialize(*fields : *T)
      @fields = fields
    end

    # Serialises `self` in a format suitable for log messages.
    def to_s(io : IO)
      io << '‹'
      to_io io
      io << '›'
    end

    # Writes `self` to the passed *io*.
    def to_io(io : IO, format = IO::ByteFormat::SystemEndian)
      @fields.each.flatten.each do |field|
        io << field
      end
    end

    # Syntactical suger for `Command` definition. Provides the ability to express
    # command fields in the same way as `Byte` objects and other similar
    # collections from the Crystal std lib.
    macro [](*fields)
      Extron::SIS::Command.new {{*fields}}
    end
  end
end

