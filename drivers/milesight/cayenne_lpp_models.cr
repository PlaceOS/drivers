require "base64"
require "bindata"

# https://resource.milesight.com/milesight/iot/document/vs321-user-guide-en.pdf

module Milesight
  # item types
  enum Types : UInt16
    PowerOn         = 0xff0b # 1 byte
    ProtocolVersion = 0xff01 # 1 byte
    SerialNumber    = 0xff16 # 8 bytes
    HardwareVersion = 0xff09 # 2 bytes
    FirmwareVersion = 0xff0a # 2 bytes
    DeviceType      = 0xff0f # 1 byte
    PowerSupply     = 0xffcc # 1 byte

    AccumulatedCounter = 0x04cc # 4 bytes (in + out)
    PeriodicCounter    = 0x05cc # 4 bytes (in + out)
    Temperature        = 0x0367 # 2 bytes, 0.1 °C, signed MSB (little-endian)
    Humidity           = 0x0468 # 1 byte, 0.5 %RH
    Battery            = 0x0175 # 1 bytes, 0-100%
    Timestamp          = 0x0aEF # 4 bytes, LE, seconds
    DetectionStatus    = 0x08F4 # 2 bytes, 02 00=>Normal detection
    PeopleCounting     = 0x05FD # 2 bytes, LE
    # 4 bytes, first 2 bytes are enabled regions
    # second 2 bytes are occupancy of those regions
    DeskOccupancy = 0x06FE
    Illumination  = 0x07FF # 1 byte, 0 == dim
  end

  class Item < BinData
    endian :big

    field channel_type : UInt16

    getter type : Types? do
      Types.from_value(channel_type) rescue nil
    end

    def byte_size : Int32?
      item_type = self.type
      return unless item_type
      case item_type
      in .power_on?, .protocol_version?, .humidity?, .battery?, .illumination?, .device_type?, .power_supply?
        1
      in .hardware_version?, .firmware_version?, .temperature?,
         .detection_status?, .people_counting?
        2
      in .desk_occupancy?, .timestamp?, .accumulated_counter?, .periodic_counter?
        4
      in .serial_number?
        8
      end
    end

    field bytes : Bytes, length: -> { byte_size || io.peek.size }

    protected def parse_int16_le(bytes : Bytes)
      io = IO::Memory.new(bytes)
      io.read_bytes(Int16, IO::ByteFormat::LittleEndian)
    end

    protected def parse_uint32_le(bytes : Bytes)
      io = IO::Memory.new(bytes)
      io.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    end

    def value
      item_type = self.type
      case item_type
      when nil, Nil
        bytes
      when .temperature?
        parse_int16_le(bytes) / 10
      when .people_counting?
        parse_int16_le(bytes)
      when .timestamp?
        Time.unix parse_uint32_le(bytes)
      when .humidity?
        bytes[0] / 2
      when .accumulated_counter?, .periodic_counter?
        in_count = parse_int16_le(bytes[0...2]).to_i
        out_count = parse_int16_le(bytes[2...4]).to_i

        in_count - out_count
      when .illumination?, .battery?, .protocol_version?
        bytes[0]
      when .power_on?
        bytes[0] == 0xff_u8
      else
        bytes
      end
    end
  end

  class Frame < BinData
    endian :big

    # Keep reading LppItem while there are bytes remaining.
    # read_next gets the partially-built array and can inspect IO via parent.io
    field items : Array(Item), read_next: -> {
      if bytes = io.peek
        bytes.size >= 2
      end
    }
  end
end
