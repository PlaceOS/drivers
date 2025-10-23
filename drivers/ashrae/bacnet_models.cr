require "bacnet"
require "json"

module Ashrae
  class DeviceAddress
    include JSON::Serializable

    def initialize(@ip, @id, @net, @addr)
    end

    getter ip : String
    getter id : UInt32?
    getter net : UInt16?
    getter addr : String?

    def address
      if @ip.includes?(".")
        Socket::IPAddress.new(@ip, 0xBAC0)
      else
        @ip.hexbytes
      end
    end

    def identifier
      ::BACnet::ObjectIdentifier.new :device, @id.not_nil!
    end
  end

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
    field data_size : UInt32, value: -> { data.size }
    field data : Bytes, length: -> { data_size }
  end
end
