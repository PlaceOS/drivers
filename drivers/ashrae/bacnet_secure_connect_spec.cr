require "placeos-driver/spec"
require "bacnet"

# NOTE:: driver specs run the transport in RAW mode, so the websocket framing
# that BACnet/SC would normally use is not present here - each `responds` is a
# single BVLC message, exactly as it would arrive in a websocket frame.
alias Secure = BACnet::Message::Secure
alias PropertyType = BACnet::PropertyIdentifier::PropertyType
alias ValueObjects = Array(BACnet::Object | BACnet::Objects)

DriverSpecs.mock_driver "Ashrae::BACnetSecureConnect" do
  # the device we are pretending to be on the other side of the hub
  device_vmac = Bytes[0x00, 0x11, 0x22, 0x33, 0x44, 0x55]
  device_id = 389999_u32
  object_id = BACnet::ObjectIdentifier.new(:analog_value, 1)
  binding = "#{device_id}.AnalogValue[1]"

  parse = ->(bytes : Bytes) { IO::Memory.new(bytes).read_bytes(Secure) }

  read_property = ->(request : Secure) { BACnet::Client::Message::ReadProperty.parse(request) }

  char_string = ->(text : String) { BACnet::Object.new.set_character_string(text) }

  # a message from the device, encapsulating a network layer request
  device_message = -> do
    data_link = Secure::BVLCI.new
    data_link.request_type = Secure::Request::EncapsulatedNPDU
    data_link.message_id = 100_u16
    data_link.source_address = device_vmac
    Secure.new(data_link, BACnet::NPDU.new)
  end

  # builds the response to a read property request, echoing the object and
  # property that was requested along with the invoke id
  complex_ack = ->(request : Secure, values : ValueObjects) do
    details = read_property.call(request)
    BACnet::Client::Message::ComplexAck.build(
      device_message.call,
      request.application.as(BACnet::ConfirmedRequest).invoke_id.not_nil!,
      BACnet::ConfirmedService::ReadProperty,
      details[:object_id], details[:property], values, details[:index]
    )
  end

  # ===========================================================
  # Connection: the driver sends a connect request as soon as the
  # transport is available and waits for the hub to accept it
  # ===========================================================

  connect_request = parse.call(expect_send)
  connect_request.data_link.request_type.should eq(Secure::Request::ConnectRequest)
  connect_request.data_link.connect_details.vmac.size.should eq(6)
  connect_request.data_link.connect_details.device_uuid.size.should eq(16)

  accept = Secure::BVLCI.new
  accept.request_type = Secure::Request::ConnectAccept
  accept.message_id = connect_request.data_link.message_id
  accept.connect_details.vmac = Bytes[0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f]
  accept.connect_details.device_uuid = UUID.v4.bytes.to_slice
  accept.connect_details.max_bvlc_length = 1440_u16
  accept.connect_details.max_npdu_length = 1420_u16
  responds(Secure.new(accept))

  # ===========================================================
  # Discovery: connecting triggers a WhoIs broadcast, we reply with
  # an IAm which is how the device is added to the seen devices
  # ===========================================================

  who_is = parse.call(expect_send)
  who_is.data_link.destination_broadcast?.should eq(true)
  who_is.application.as(BACnet::UnconfirmedRequest).service.who_is?.should eq(true)

  i_am = BACnet::Client::Message::IAm.build(
    device_message.call,
    BACnet::ObjectIdentifier.new(:device, device_id),
    1476, BACnet::SegmentationSupport::NotSupported, 389
  )
  responds(i_am)

  # ===========================================================
  # Inspection: 5 seconds after connecting the driver queries the
  # devices it has seen, reading the device details then walking
  # the object list
  # ===========================================================

  request = parse.call(expect_send(8.seconds))
  details = read_property.call(request)
  details[:object_id].instance_number.should eq(device_id)
  details[:property].should eq(PropertyType::ObjectName)
  responds complex_ack.call(request, ValueObjects{char_string.call("BACnet Test Device")})

  request = parse.call(expect_send(2.seconds))
  read_property.call(request)[:property].should eq(PropertyType::VendorName)
  responds complex_ack.call(request, ValueObjects{char_string.call("PlaceOS")})

  request = parse.call(expect_send(2.seconds))
  read_property.call(request)[:property].should eq(PropertyType::ModelName)
  responds complex_ack.call(request, ValueObjects{char_string.call("Virtual Controller")})

  # index 0 of the object list is the number of objects on the device
  request = parse.call(expect_send(2.seconds))
  details = read_property.call(request)
  details[:property].should eq(PropertyType::ObjectList)
  details[:index].should eq(0)
  responds complex_ack.call(request, ValueObjects{BACnet::Object.new.set_value(2_u32)})

  # index 1 is the device itself, so the scan starts at index 2
  request = parse.call(expect_send(2.seconds))
  details = read_property.call(request)
  details[:property].should eq(PropertyType::ObjectList)
  details[:index].should eq(2)
  responds complex_ack.call(request, ValueObjects{BACnet::Object.new.set_value(object_id, tag: 12)})

  request = parse.call(expect_send(2.seconds))
  details = read_property.call(request)
  details[:object_id].object_type.should eq(BACnet::ObjectIdentifier::ObjectType::AnalogValue)
  details[:property].should eq(PropertyType::ObjectName)
  responds complex_ack.call(request, ValueObjects{char_string.call("Room Temperature")})

  request = parse.call(expect_send(2.seconds))
  read_property.call(request)[:property].should eq(PropertyType::Units)
  responds complex_ack.call(request, ValueObjects{BACnet::Object.new.set_value(BACnet::Unit::DegreesCelsius)})

  # the object is exposed as state once the device has been inspected,
  # the value is unknown until it has been read
  state = status[binding]
  state["obj_id"].should eq(binding)
  state["obj_value"].raw.should be_nil

  device = exec(:device, device_id).get.not_nil!
  device["name"].should eq("BACnet Test Device")
  device["vendor_name"].should eq("PlaceOS")
  device["objects"].as_a.size.should eq(1)
  device["objects"][0]["name"].should eq("Room Temperature")

  # ===========================================================
  # query_value reads the present value and resolves the task with
  # the same payload that is exposed as state
  # ===========================================================

  response = exec(:query_value, device_id, 1_u32, "AnalogValue")

  request = parse.call(expect_send(2.seconds))
  details = read_property.call(request)
  details[:object_id].instance_number.should eq(1)
  details[:property].should eq(PropertyType::PresentValue)
  responds complex_ack.call(request, ValueObjects{BACnet::Object.new.set_value(21.5_f32)})

  value = response.get.not_nil!
  value["obj_id"].should eq(binding)
  value["obj_value"].should eq(21.5)
  value["clock"].as_i64.should be > 0

  # state is updated with the value that was returned
  status[binding].should eq(value)

  # the sensor interface exposes the same reading
  sensor = exec(:sensor, device_id.to_s, "AnalogValue[1]").get.not_nil!
  sensor["value"].should eq(21.5)
  sensor["type"].should eq("temperature")
  sensor["unit"].should eq("Cel")
  sensor["binding"].should eq(binding)

  # ===========================================================
  # update_value performs the same read, however it is fire and
  # forget - the caller is not sent the value, only state is updated
  # ===========================================================

  response = exec(:update_value, device_id, 1_u32, "AnalogValue")
  response.get.raw.should be_nil

  request = parse.call(expect_send(2.seconds))
  read_property.call(request)[:property].should eq(PropertyType::PresentValue)
  responds complex_ack.call(request, ValueObjects{BACnet::Object.new.set_value(23.5_f32)})
  sleep 200.milliseconds

  status[binding]["obj_value"].should eq(23.5)

  # ===========================================================
  # a device that fails to respond aborts the task (rather than
  # leaving the caller waiting) and doesn't wedge the queue
  # ===========================================================

  response = exec(:query_value, device_id, 1_u32, "AnalogValue")
  parse.call(expect_send(2.seconds)).data_link.request_type.should eq(Secure::Request::EncapsulatedNPDU)
  # no response sent, the client gives up after 2 seconds
  expect_raises(PlaceOS::Driver::RemoteException) { response.get }

  response = exec(:query_value, device_id, 1_u32, "AnalogValue")
  request = parse.call(expect_send(2.seconds))
  responds complex_ack.call(request, ValueObjects{BACnet::Object.new.set_value(22.5_f32)})
  response.get.not_nil!["obj_value"].should eq(22.5)
end
