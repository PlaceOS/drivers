# # Generated from streaming.proto for StreamMessage
require "protobuf"

module HPE::ANW::StreamMessage
  struct MsgProto
    include ::Protobuf::Message

    contract_of "proto3" do
      optional :subject, :string, 2
      optional :data, :bytes, 3
      optional :timestamp, :int64, 4
      optional :customer_id, :string, 5
      optional :msp_id, :string, 6
    end
  end
end
