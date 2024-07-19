require "bindata"

class DispatchProtocol < BinData
  endian big

  enum MessageType : UInt8
    OPENED
    CLOSED
    RECEIVED
    WRITE
    CLOSE
  end

  field message : MessageType = MessageType::RECEIVED
  field ip_address : String
  field id_or_port : UInt64
  field data_size : UInt32, value: ->{ data.size }
  field data : Bytes, length: ->{ data_size }
end
