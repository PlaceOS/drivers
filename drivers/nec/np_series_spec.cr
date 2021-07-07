require "placeos-driver/driver-specs/runner"

# NOTES
# (*1) Projector ID
# (*2) Model code: "xxH" inscription
# (*3) Checksum: "CKS" inscription
# (*4) Response error number
# (*5) Term “RGB” and “COMPUTER”
# (*6) Term “DVI” and “COMPUTER”

DriverSpecs.mock_driver "Nec::Projector" do
  p_id = 0x00_u8 # Projector ID
  mdlc = 0x10_u8 # Model code

  # do_poll
  # power?
  should_send(Bytes[0x00, 0x81, 0x00, 0x00, 0x00, 0x81, 0x02])
  responds(Bytes[0x20, 0x81, p_id, mdlc, 0x10, 0b_0000_0010, 0xC3])
  status[:power].should eq(true)
  # input?
  should_send(Bytes[0x00, 0x85, 0x00, 0x00, 0x01, 0x02, 0x88])
  responds(Bytes[0x20, 0x85, p_id, mdlc, 0x10,
    # Data, simplified for sanity
    # We only care about the ones with 0x
    # -17    -15  -14
    0x00, 2, 0x01, 0x06, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    0x4C]) # Checksum
  status[:input].should eq("HDMI")
  # mute?
  should_send(Bytes[0x00, 0x85, 0x00, 0x00, 0x01, 0x03, 0x89])
  responds(Bytes[0x20, 0x85, p_id, mdlc, 0x10,
    # -17  -16  -15
    0x00, 0x00, 0x00, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
    0x47]) # Checksum
  status[:mute].should eq(false)
  status[:picture_mute].should eq(false)
  status[:audio_mute].should eq(false)
  status[:onscreen_mute].should eq(false)
  # background_black
  should_send(Bytes[0x03, 0xB1, 0x00, 0x00, 0x02, 0x0B, 0x01, 0xC2])
  responds(Bytes[0x23, 0xB1, p_id, mdlc, 0x02, 0x0B, 0xF1])
  # lamp_info
  should_send(Bytes[0x03, 0x8A, 0x00, 0x00, 0x00, 0x8D, 0x1A])
  # 5 for header, 1 for checksum and 98 for data
  response = Bytes.new(104)
  response.copy_from(Bytes[0x23, 0x8A, p_id, mdlc, 0x62, 0x0B]) # header
  # data
  # lamp usage
  response[87] = 0xC0
  response[88] = 0x65
  response[89] = 0x52
  # filter usage
  response[92] = 0xE4
  response[93] = 0x57
  # checksum
  response[-1] = 0xDC
  responds(response)
  status[:lamp_usage].should eq(1500)
  status[:filter_usage].should eq(1600)

  exec(:volume, 100)
  should_send(Bytes[0x03, 0x10, 0x00, 0x00, 0x05, 0x05, 0x00, 0x00, 0x3F, 0x00, 0x5C])
  responds(Bytes[0x23, 0x10, p_id, mdlc, 0x05, 0x00, 0x48])
  status[:volume].should eq(63)

  exec(:mute)
  # mute_picture
  should_send(Bytes[0x02, 0x10, 0x00, 0x00, 0x00, 0x12, 0x24])
  responds(Bytes[0x22, 0x10, p_id, mdlc, 0x32, 0x00, 0x74])
  status[:mute] = true
  status[:picture_mute] = true
  # mute_onscreen
  should_send(Bytes[0x02, 0x14, 0x00, 0x00, 0x00, 0x16, 0x2C])
  responds(Bytes[0x22, 0x14, p_id, mdlc, 0x00, 0x46])
  status[:onscreen_mute] = true
  # mute_audio
  should_send(Bytes[0x02, 0x12, 0x00, 0x00, 0x00, 0x14, 0x28])
  responds(Bytes[0x22, 0x12, p_id, mdlc, 0x00, 0x44])
  status[:audio_mute] = true

  exec(:switch_audio, "VGA")
  should_send(Bytes[0x03, 0xB1, 0x00, 0x00, 0x02, 0xC0, 0x01, 0x77])
  responds(Bytes[0x23, 0xB1, p_id, mdlc, 0xC0, 0x01, 0xA5])
  status[:audio_input].should eq("VGA")
end
