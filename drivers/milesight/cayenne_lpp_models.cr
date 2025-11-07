require "base64"
require "bindata"

# https://resource.milesight.com/milesight/iot/document/vs321-user-guide-en.pdf

module Milesight
  # item types
  enum Types : UInt8
    DigitalInput        = 0x00_u8 # 1 bytes
    DigitalOutput       = 0x01_u8 # 1 bytes
    AnalogInput         = 0x02_u8 # 2 bytes
    AnalogOutput        = 0x03_u8 # 2 bytes
    SerialNumber        = 0x08_u8 # 6 bytes
    HardwareVersion     = 0x09_u8 # 6 bytes
    RestartNotification = 0x0B_u8 # 4 bytes
    TempAlarm           = 0x0D_u8 # 7 bytes
    Illuminance         = 0x65_u8 # 2 bytes, 1 lux
    Presence            = 0x66_u8 # 2 bytes
    Temperature         = 0x67_u8 # 2 bytes, 0.1 °C, signed MSB (little-endian)
    Humidity            = 0x68_u8 # 1 byte, 0.5 %RH
    Accelerometer       = 0x71_u8 # 6 bytes
    Barometer           = 0x73_u8 # 2 bytes
    Battery             = 0x75_u8 # 1 bytes, 0-100%
    Gyrometer           = 0x86_u8 # 6 bytes
    GPSLocation         = 0x88_u8 # 9 bytes, lat, lon, altitude in meters
    Timestamp           =    0xEF # 4 bytes, LE, seconds
    DetectionStatus     = 0xF4_u8 # 2 bytes, 02 00=>Normal detection
    PeopleCounting      = 0xFD_u8 # 2 bytes, LE
    # 4 bytes, first 2 bytes are enabled regions
    # second 2 bytes are occupancy of those regions
    DeskOccupancy = 0xFE_u8
    Illumination  = 0xFF_u8 # 1 byte, 0 == dim
  end

  class Item < BinData
    endian :big

    field channel : UInt8
    field dtype : UInt8

    getter type : Types? do
      Types.from_value(dtype) rescue nil
    end

    def byte_size : Int32?
      item_type = self.type
      return unless item_type
      case item_type
      in .digital_input?, .digital_output?, .humidity?, .battery?, .illumination?
        1
      in .analog_input?, .analog_output?, .illuminance?,
         .presence?, .temperature?, .barometer?, .detection_status?,
         .people_counting?
        2
      in .restart_notification?, .desk_occupancy?, .timestamp?
        4
      in .accelerometer?, .gyrometer?, .serial_number?, .hardware_version?
        6
      in .temp_alarm?
        7
      in .gps_location?
        9
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
      when .illumination?, .battery?
        bytes[0]
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
