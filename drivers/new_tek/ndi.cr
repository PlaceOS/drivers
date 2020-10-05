require "bindata"

module NewTek; end

# Documentation: https://code.videolan.org/jbk/libndi

module NewTek::NDI
  XOR_TABLE = Bytes[
    0x4e, 0x44, 0x49, 0xae, 0x2c, 0x20, 0xa9, 0x32, 0x30, 0x31, 0x37, 0x20,
    0x4e, 0x65, 0x77, 0x54, 0x65, 0x6b, 0x2c, 0x20, 0x50, 0x72, 0x6f, 0x70,
    0x72, 0x69, 0x65, 0x74, 0x79, 0x20, 0x61, 0x6e, 0x64, 0x20, 0x43, 0x6f,
    0x6e, 0x66, 0x69, 0x64, 0x65, 0x6e, 0x74, 0x69, 0x61, 0x6c, 0x2e, 0x20,
    0x59, 0x6f, 0x75, 0x20, 0x61, 0x72, 0x65, 0x20, 0x69, 0x6e, 0x20, 0x76,
    0x69, 0x6f, 0x6c, 0x61, 0x74, 0x69, 0x6f, 0x6e, 0x20, 0x6f, 0x66, 0x20,
    0x74, 0x68, 0x65, 0x20, 0x4e, 0x44, 0x49, 0xae, 0x20, 0x53, 0x44, 0x4b,
    0x20, 0x6c, 0x69, 0x63, 0x65, 0x6e, 0x73, 0x65, 0x20, 0x61, 0x74, 0x20,
    0x68, 0x74, 0x74, 0x70, 0x3a, 0x2f, 0x2f, 0x6e, 0x65, 0x77, 0x2e, 0x74,
    0x6b, 0x2f, 0x6e, 0x64, 0x69, 0x73, 0x64, 0x6b, 0x5f, 0x6c, 0x69, 0x63,
    0x65, 0x6e, 0x73, 0x65, 0x2f, 0x00, 0x00, 0x00,
  ]

  enum DataType
    Video = 0
    Audio
    Text
  end

  class Message < BinData
    endian little

    uint16 :scrambling_hint, value: ->{ 0x8001_u16 }
    enum_field UInt16, data_type : DataType = DataType::Text

    uint32 :header_length, value: ->{ header_data.size + 8 }
    bytes :header_data, length: ->{ header_length - 8 }

    uint32 :payload_length, value: ->{ payload_data.size - 8 }

    # Scrambles from here
    # Adds 8 * 0-bytes to start of payload
    bytes :payload_data, length: ->{ payload_length + 8 }

    def scramble_seed
      # allow overflow to occur
      (header_length &+ payload_length).to_u64

      64_u64
    end

    def scramble_type
      scrambling_type = 1

      if data_type.video? && scrambling_hint > 3
        scrambling_type = 2
      elsif data_type.audio? && scrambling_hint > 2
        scrambling_type = 2
      elsif data_type.text? && scrambling_hint > 2
        scrambling_type = 2
      end

      scrambling_type
    end

    def scramble_type1
      seed = scramble_seed
      seed = (seed << 32) | seed
      seed1 = seed ^ 0xb711674bd24f4b24_u64
      seed2 = seed ^ 0xb080d84f1fe3bf44_u64

      length = payload_data.size
      buf = IO::Memory.new(payload_data)

      if length >= 8
        qwords = length // 8
        tmp1 = seed1
        (0...qwords).each do
          word = buf.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
          seed1 = seed2
          tmp1 = tmp1 ^ (tmp1 << 23)
          tmp1 = (((seed1 >> 9) ^ tmp1) >> 17) ^ tmp1 ^ seed1
          seed2 = tmp1 ^ word
          word = word ^ (tmp1 &+ seed1)
          tmp1 = seed1

          buf.pos -= 8
          buf.write_bytes(word, IO::ByteFormat::LittleEndian)
        end
      end

      remaining = length % 8
      if remaining > 0
        final = Bytes.new(8)
        buf.read(final)
        final = IO::Memory.new(final)
        remainder = final.read_bytes(UInt64, IO::ByteFormat::LittleEndian)

        seed1 = seed1 ^ (seed1 << 23)
        seed1 = (((seed2 >> 9) ^ seed1) >> 17) ^ seed1 ^ seed2

        final.rewind
        final.write_bytes(remainder ^ (seed1 &+ seed2), IO::ByteFormat::LittleEndian)

        buf.pos -= remaining
        buf.write(final.to_slice[0...remaining])
      end
    end

    def unscramble_type1
      seed = scramble_seed
      seed = (seed << 32) | seed
      seed1 = seed ^ 0xb711674bd24f4b24_u64
      seed2 = seed ^ 0xb080d84f1fe3bf44_u64

      length = payload_data.size
      buf = IO::Memory.new(payload_data)

      if length >= 8
        qwords = length // 8
        tmp1 = seed1
        (0...qwords).each do
          word = buf.read_bytes(UInt64, IO::ByteFormat::LittleEndian)
          seed1 = seed2
          tmp1 = tmp1 ^ (tmp1 << 23)
          tmp1 = (((seed1 >> 9) ^ tmp1) >> 17) ^ tmp1 ^ seed1

          # Note:: This is where unscramble differs from scramble
          # (order of operations)
          word = word ^ (tmp1 &+ seed1)
          seed2 = tmp1 ^ word
          tmp1 = seed1

          buf.pos -= 8
          buf.write_bytes(word, IO::ByteFormat::LittleEndian)
        end
      end

      remaining = length % 8
      if remaining > 0
        final = Bytes.new(8)
        buf.read(final)
        final = IO::Memory.new(final)
        remainder = final.read_bytes(UInt64, IO::ByteFormat::LittleEndian)

        seed1 = seed1 ^ (seed1 << 23)
        seed1 = (((seed2 >> 9) ^ seed1) >> 17) ^ seed1 ^ seed2

        final.rewind
        final.write_bytes(remainder ^ (seed1 &+ seed2), IO::ByteFormat::LittleEndian)

        buf.pos -= remaining
        buf.write(final.to_slice[0...remaining])
      end
    end

    def unscramble_type2
      xor_len = 128_i64
      seed = scramble_seed.to_i64
      length = payload_data.size.to_i64

      buf = IO::Memory.new(payload_data)

      if length >= 8
        len8 = length >> 3

        (0...len8).each do
          word = buf.read_bytes(Int64, IO::ByteFormat::LittleEndian)
          tmp = seed
          seed = word & 0xffffffff_i64
          word = ((tmp &* length &* -0x61c8864680b583eb_i64 &+ 0xc42bd7dee6270f1b_u64) ^ word) &* -0xe217c1e66c88cc3_i64 &+ 0x2daa8c593b1b4591_i64

          buf.pos -= 8
          buf.write_bytes(word, IO::ByteFormat::LittleEndian)
        end
      end

      xor_len = length if length < xor_len
      (0...xor_len).each do |index|
        payload_data[index] ^= XOR_TABLE[index]
      end
    end

    def self.build_text_message(message : String) : Message
      ndi = Message.new
      ndi.payload_length = (message.bytesize + 9).to_u32
      ndi.header_length = 8_u32
      ndi.scrambling_hint = 0x8001_u16

      # 8 char buffer + terminating null byte
      payload = IO::Memory.new(message.bytesize + 9)
      payload.pos = 8
      payload.write message.to_slice
      payload.write_byte 0_u8
      ndi.payload_data = payload.to_slice

      ndi.scramble_type1
      ndi
    end

    def extract_text : String
      if scramble_type == 1
        unscramble_type1
      else
        unscramble_type2
      end

      # ignore padding and null termination
      String.new(payload_data[8..-2])
    end
  end # class Message
end   # module NewTek::NDI
