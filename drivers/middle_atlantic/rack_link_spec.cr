require "placeos-driver/spec"
require "./rack_link_protocol"

DriverSpecs.mock_driver "MiddleAtlantic::RackLink" do
  login = MiddleAtlantic::RackLinkProtocol.login_packet("user", "password")
  pong  = MiddleAtlantic::RackLinkProtocol.pong_response

  # data from protocol doc
  login_hex = "fe10000201" + "757365727c70617373776f7264" + "3FFF"
  login.should eq login_hex.hexbytes

  # Login
  should_send login
  responds Bytes[0xFE, 0x04, 0x00, 0x02, 0x10, 0x01, 0x15, 0xFF] # login accepted

  # simulate ping
  transmit Bytes[0xFE, 0x03, 0x00, 0x01, 0x01, 0x03, 0xFF] # PING
  should_send pong

  # query outlet states (assume 8 outlets)
  1.upto(8) do |id|
    query = MiddleAtlantic::RackLinkProtocol.query_outlet(id.to_u8)
    should_send query
    # outlet alternating states
    responds Bytes[0xFE, 0x09, 0x00, 0x20, 0x10, id.to_u8, (id % 2).to_u8, 0x30, 0x30, 0x30, 0x30, 0x00, 0xFF]
    status["outlet_#{id}"].should eq(id.odd?)
  end

  # Test ON
  exec(:power_on, 2)
  should_send MiddleAtlantic::RackLinkProtocol.set_outlet(2_u8, 1_u8)
  responds Bytes[0xFE, 0x09, 0x00, 0x20, 0x10, 0x02, 0x01, 0x30, 0x30, 0x30, 0x30, 0x00, 0xFF]
  status["outlet_2"].should eq(true)

  # Test OFF
  exec(:power_off, 2)
  should_send MiddleAtlantic::RackLinkProtocol.set_outlet(2_u8, 0_u8)
  responds Bytes[0xFE, 0x09, 0x00, 0x20, 0x10, 0x02, 0x00, 0x30, 0x30, 0x30, 0x30, 0x00, 0xFF]
  status["outlet_2"].should eq(false)

  # Cycle
  exec(:power_cycle, 1, 5)
  should_send MiddleAtlantic::RackLinkProtocol.cycle_outlet(1_u8, 5)

  # Sequencing up
  exec(:sequence_up)
  should_send MiddleAtlantic::RackLinkProtocol.build(Bytes[0x00, 0x36, 0x01, 0x01] + "0003".to_slice)

  # Sequencing down
  exec(:sequence_down)
  should_send MiddleAtlantic::RackLinkProtocol.build(Bytes[0x00, 0x36, 0x01, 0x03] + "0003".to_slice)

  # NACK Handling
  responds Bytes[0xFE, 0x04, 0x00, 0x10, 0x10, 0x08, 0x3F, 0xFF] # NACK - invalid credentials
end
