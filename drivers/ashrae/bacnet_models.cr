require "bacnet"
require "json"

module Ashrae
  class DeviceAddress
    include JSON::Serializable

    def initialize(@ip, @id, @net, @addr, @name, @model_name, @vendor_name)
    end

    getter ip : String
    getter id : UInt32?
    getter net : UInt16?
    getter addr : String?

    def address
      Socket::IPAddress.new(@ip, 0xBAC0)
    end

    def identifier
      ::BACnet::ObjectIdentifier.new :device, @id.not_nil!
    end
  end

  class DispatchProtocol < BinData
    endian big

    enum MessageType
      OPENED
      CLOSED
      RECEIVED
      WRITE
      CLOSE
    end

    enum_field UInt8, message : MessageType = MessageType::RECEIVED
    string :ip_address
    uint64 :id_or_port
    uint32 :data_size, value: ->{ data.size }
    bytes :data, length: ->{ data_size }, default: Bytes.new(0)
  end
end
