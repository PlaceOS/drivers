require "./sis/*"

# Implementation, types and utilities for working with the Extron Simple
# Instruction Set (SIS) device control protocol.
#
# This protocol is used for control of all Extron signal distribution,
# processing and general audio-visual products via SSH, telnet and serial
# control.
module Extron::SIS
  TELNET_PORT =    23
  SSH_PORT    = 22023

  DELIMITER = "\r\n"

  # Illegal characters for use in property names.
  SPECIAL_CHARS = "+-,@=‘[]{}<>`“;:|?".chars

  # Symbolic type for representating a successfull interactions no useful data.
  struct Ok; end

  # Device error numbers
  enum Error
    InvalidInput           =  1
    InvalidCommand         = 10
    InvalidPresent         = 11
    InvalidOutput          = 12
    InvalidParameter       = 13
    InvalidForConfig       = 14
    Timeout                = 17
    Busy                   = 22
    PrivilegesViolation    = 24
    DeviceNotPresent       = 25
    MaxConnectionsExceeded = 26
    InvalidEventNumber     = 27
    FileNotFound           = 28

    def retryable?
      timeout? || busy?
    end
  end

  alias Input = UInt16

  alias Output = UInt16

  # Layers for targetting signal distribution operations.
  enum MatrixLayer : UInt8
    All = 0x21 # '!'
    Aud = 0x24 # '$'
    Vid = 0x25 # '%'
    RGB = 0x26 # '&'

    def includes_video?
      All || Vid || RGB
    end

    def includes_audio?
      All || Aud
    end
  end

  # Struct for representing a matrix signal path.
  record Tie, input : Input, output : Output, layer : MatrixLayer

  # Struct for representing a broadcast signal path, or single output switch.
  record Switch, input : Input, layer : MatrixLayer

  # IO capacity for a switching layer.
  record MatrixSize, inputs : Input, outputs : Output

  # IO capacity for a full device.
  record SwitcherInformation, video : MatrixSize, audio : MatrixSize
end
