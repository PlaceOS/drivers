require "bindata"

class Wolfvision::Packet < BinData
  endian big

  bit_field do
    bool :error, default: false
    bits 3, :head_reserved
    bool :two_byte_cmd, default: false
    bool :two_byte_length, default: false
    bool :two_byte_header, default: false
    bool :set_cmd, default: false
  end

  bit_field onlyif: ->{ two_byte_header } do
    bits 7, :ext_head_reserved
    bool :four_byte_length, default: false
  end

  uint8 :short_cmd, onlyif: ->{ !two_byte_cmd }
  uint16 :long_cmd, onlyif: ->{ two_byte_cmd }

  def command : UInt16
    two_byte_cmd ? long_cmd : short_cmd.to_u16
  end

  def command=(number : Int)
    if number > UInt8::MAX
      self.long_cmd = number.to_u16
      self.two_byte_cmd = true
    else
      self.short_cmd = number.to_u8
      self.two_byte_cmd = false
    end
    number
  end

  uint8 :byte_len, onlyif: ->{ !four_byte_length && !two_byte_length }
  uint16 :short_len, onlyif: ->{ !four_byte_length && two_byte_length }
  uint32 :long_len, onlyif: ->{ four_byte_length }

  def length : UInt32
    four_byte_length ? long_len : (two_byte_length ? short_len.to_u32 : byte_len.to_u32)
  end

  def length=(number : Int)
    if number > UInt16::MAX
      self.four_byte_length = number.to_u32
      self.two_byte_header = true
      self.two_byte_length = false
      self.four_byte_length = true
    elsif number > UInt8::MAX
      self.short_len = number.to_u16
      self.two_byte_header = false
      self.two_byte_length = true
      self.four_byte_length = false
    else
      self.byte_len = number.to_u8
      self.two_byte_header = false
      self.two_byte_length = false
      self.four_byte_length = false
    end
    number
  end

  bytes :payload, length: ->{ length }, onlyif: ->{ !error }
end