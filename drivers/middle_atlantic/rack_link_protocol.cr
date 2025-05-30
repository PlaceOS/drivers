module MiddleAtlantic::RackLinkProtocol
  HEADER    = 0xFE_u8
  TAIL      = 0xFF_u8
  ESCAPE    = 0xFD_u8
  PROTECTED = Set{HEADER, TAIL, ESCAPE}

  def self.checksum(payload : Bytes) : UInt8
    sum = payload.reduce(0_u16) { |s, b| s + b } & 0x7F
    sum.to_u8
  end

  def self.escape(bytes : Bytes) : Bytes
    output = IO::Memory.new
    bytes.each do |byte|
      if PROTECTED.includes?(byte)
        output.write_byte(ESCAPE)
        output.write_byte(~byte)
      else
        output.write_byte(byte)
      end
    end
    output.to_slice
  end

  def self.build(command : Bytes) : Bytes
    command = escape(command)
    length = command.size.to_u8
    frame = Bytes[HEADER, length] + command
    checksum = checksum(frame)
    frame + Bytes[checksum, TAIL]
  end

  def self.login_packet(user : String, pass : String) : Bytes
    data = Bytes[0x00, 0x02, 0x01] + "#{user}|#{pass}".to_slice
    build(data)
  end

  def self.pong_response : Bytes
    build(Bytes[0x00, 0x01, 0x10])
  end

  def self.query_outlet(outlet : UInt8) : Bytes
    build(Bytes[0x00, 0x20, 0x02, outlet])
  end

  def self.set_outlet(outlet : UInt8, state : UInt8) : Bytes
    data = Bytes[0x00, 0x20, 0x01, outlet, state] + "0000".to_slice
    build(data)
  end

  def self.cycle_outlet(outlet : UInt8, seconds : Int32 = 5) : Bytes
    cycle = sprintf("%04d", seconds).to_slice
    data = Bytes[0x00, 0x20, 0x01, outlet, 0x02] + cycle
    build(data)
  end
end
