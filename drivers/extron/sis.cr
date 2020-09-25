require "./sis/*"

# Implementation, types and utilities for working with the Extron Simple
# Instruction Set (SIS) device control protocol.
#
# This protocol is used for control of all Extron signal distribution,
# processing and general audio-visual products via SSH, telnet and serial
# control.
module Extron::SIS
  DELIMITER = 0x0d

  # Transmitted when a connection is opened with the device.
  struct CopyrightMessage
  end

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

end

