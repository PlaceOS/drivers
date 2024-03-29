require "placeos-driver/spec"

DriverSpecs.mock_driver "Sony::Camera::VISCA" do
  # reset the sequence number
  puts "Testing sequence reset"
  should_send Bytes[0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01]
  responds Bytes[0x02, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01]

  # clear the interface socket
  puts "Testing interface clear"
  should_send Bytes[0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x02, 0x81, 0x01, 0x00, 0x01, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, 0x90, 0x50, 0xFF]

  puts "Testing camera go-home"
  exec :home
  should_send Bytes[0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x03, 0x81, 0x01, 0x06, 0x04, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03, 0x90, 0x40, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03, 0x90, 0x50, 0xFF]

  # Should then query the current camera position
  puts "Testing camera pan tilt position query"
  should_send Bytes[0x01, 0x10, 0x00, 0x05, 0x00, 0x00, 0x00, 0x04, 0x81, 0x09, 0x06, 0x12, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x90, 0x40, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x04, 0x90, 0x50,
    0x0B, 0x0E, 0x0E, 0x0F, # pan pos
    0x01, 0x02, 0x03, 0x04, # tilt pos
    0xFF,
  ]

  # Check the positions are parsed correctly
  puts "Confirming pan tilt position parsing"
  exec(:pan_pos).get.should eq 0xBEEF
  exec(:tilt_pos).get.should eq 0x1234

  # should be able to set the camera position
  puts "Check pan tilt request"
  exec(:pantilt, 0x3456, 0x7890, 0xFF)
  should_send Bytes[0x01, 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00, 0x05, 0x81, 0x01,
    0x06, 0x02,
    0x0F, 0x00,             # speed
    0x03, 0x04, 0x05, 0x06, # pan pos
    0x07, 0x08, 0x09, 0x00, # tilt pos
    0xFF,
  ]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x05, 0x90, 0x40, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x05, 0x90, 0x50, 0xFF]

  # Should then query the current camera position
  puts "Should query pan tilt position"
  should_send Bytes[0x01, 0x10, 0x00, 0x05, 0x00, 0x00, 0x00, 0x06, 0x81, 0x09, 0x06, 0x12, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x06, 0x90, 0x40, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x06, 0x90, 0x50,
    0x03, 0x04, 0x05, 0x06, # pan pos
    0x07, 0x08, 0x09, 0x00, # tilt pos
    0xFF,
  ]

  # Check the positions are parsed correctly
  puts "Confirming pan tilt position were updated"
  exec(:pan_pos).get.should eq 0x3456
  exec(:tilt_pos).get.should eq 0x7890

  puts "Zoom to an absolute position"
  exec(:zoom_to, 25.0)
  should_send Bytes[0x01, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x07, 0x81, 0x01,
    0x04, 0x47,
    0x01, 0x00, 0x00, 0x00, # zoom value
    0xFF,
  ]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x07, 0x90, 0x40, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x07, 0x90, 0x50, 0xFF]

  # Should then query the current camera zoom level
  puts "Should query zoom level"
  should_send Bytes[0x01, 0x10, 0x00, 0x05, 0x00, 0x00, 0x00, 0x08, 0x81, 0x09, 0x04, 0x47, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x03, 0x00, 0x00, 0x00, 0x08, 0x90, 0x40, 0xFF]
  responds Bytes[0x01, 0x11, 0x00, 0x07, 0x00, 0x00, 0x00, 0x08, 0x90, 0x50,
    0x01, 0x00, 0x00, 0x00, # pan pos
    0xFF,
  ]

  exec(:zoom_raw).get.should eq 0x1000
  status[:zoom].should eq 25
end
