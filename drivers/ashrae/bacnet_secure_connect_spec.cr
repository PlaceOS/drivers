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

  # ===========================================================
  # writes to a known device are sent directly to its VMAC
  # ===========================================================

  simple_ack = ->(request : Secure) do
    message = device_message.call
    ack = BACnet::SimpleAck.new
    ack.invoke_id = request.application.as(BACnet::ConfirmedRequest).invoke_id.not_nil!
    ack.service = BACnet::ConfirmedService::WriteProperty
    message.application = ack
    message
  end

  response = exec(:write_real, device_id, 1_u32, 20.0, "AnalogValue", 8)
  request = parse.call(expect_send(2.seconds))
  request.data_link.destination_address.should eq(device_vmac.hexstring)
  request.network.not_nil!.destination_specifier.should be_false
  details = BACnet::Client::Message::WriteProperty.parse(request)
  details[:object_id].instance_number.should eq(1)
  details[:priority].should eq(8)
  responds simple_ack.call(request)
  response.get.should eq(20.0)

  # ===========================================================
  # a device that hasn't been discovered is located with a WhoIs
  # limited to its instance. This device is behind a BACnet router,
  # so requests are sent to the router VMAC with a routed destination
  # ===========================================================

  router_vmac = Bytes[0x00, 0xaa, 0xbb, 0xcc, 0xdd, 0xee]
  routed_id = 400001_u32
  routed_network = 7_u16
  routed_address = "0c"
  routed_binding = "#{routed_id}.AnalogValue[3]"

  routed_i_am = -> do
    data_link = Secure::BVLCI.new
    data_link.request_type = Secure::Request::EncapsulatedNPDU
    data_link.message_id = 101_u16
    data_link.source_address = router_vmac
    npdu = BACnet::NPDU.new
    npdu.source.network = routed_network
    npdu.source_address = routed_address

    BACnet::Client::Message::IAm.build(
      Secure.new(data_link, npdu),
      BACnet::ObjectIdentifier.new(:device, routed_id),
      1476, BACnet::SegmentationSupport::NotSupported, 389
    )
  end

  response = exec(:query_value, routed_id, 3_u32, "AnalogValue")

  who_is = parse.call(expect_send(2.seconds))
  who_is.data_link.destination_broadcast?.should eq(true)
  who_is.application.as(BACnet::UnconfirmedRequest).service.who_is?.should eq(true)
  who_is.objects.map(&.as(BACnet::Object).to_u32).should eq([routed_id, routed_id])
  responds routed_i_am.call

  # the object is read while the device is inspected in the background
  properties = [] of PropertyType
  5.times do
    request = parse.call(expect_send(2.seconds))
    request.data_link.destination_address.should eq(router_vmac.hexstring)
    npdu = request.network.not_nil!
    npdu.destination.network.should eq(routed_network)
    npdu.destination_address.should eq(routed_address)

    details = read_property.call(request)
    properties << details[:property]
    value = case details[:property]
            when .present_value?
              details[:object_id].instance_number.should eq(3)
              BACnet::Object.new.set_value(19.5_f32)
            when .object_list?
              BACnet::Object.new.set_value(0_u32)
            else
              char_string.call("Routed #{details[:property]}")
            end
    responds complex_ack.call(request, ValueObjects{value})
  end
  properties.sort.should eq([
    PropertyType::ObjectName, PropertyType::VendorName, PropertyType::ModelName,
    PropertyType::ObjectList, PropertyType::PresentValue,
  ].sort)

  value = response.get.not_nil!
  value["obj_id"].should eq(routed_binding)
  value["obj_value"].should eq(19.5)
  status[routed_binding]["obj_value"].should eq(19.5)

  # the device is now known, including where it lives
  sleep 200.milliseconds
  device = exec(:device, routed_id).get.not_nil!
  device["name"].should eq("Routed ObjectName")
  device["vmac"].should eq(router_vmac.hexstring)
  device["network"].should eq(routed_network)
  device["address"].should eq(routed_address)

  # so writes no longer need a WhoIs and are routed
  response = exec(:write_unsigned_int, routed_id, 4_u32, 3, "PositiveIntegerValue", 10)
  request = parse.call(expect_send(2.seconds))
  request.data_link.destination_address.should eq(router_vmac.hexstring)
  request.network.not_nil!.destination.network.should eq(routed_network)
  request.network.not_nil!.destination_address.should eq(routed_address)
  details = BACnet::Client::Message::WriteProperty.parse(request)
  details[:object_id].object_type.should eq(BACnet::ObjectIdentifier::ObjectType::PositiveIntegerValue)
  details[:object_id].instance_number.should eq(4)
  details[:priority].should eq(10)
  responds simple_ack.call(request)
  response.get.should eq(3)

  # ===========================================================
  # concurrent requests for an unknown device share a single WhoIs
  # ===========================================================

  other_id = 500001_u32
  write1 = exec(:write_binary, other_id, 1_u32, true)
  who_is = parse.call(expect_send(2.seconds))
  who_is.objects.map(&.as(BACnet::Object).to_u32).should eq([other_id, other_id])

  # a second request while the first is waiting on the IAm.
  # NOTE:: exec clears buffered transmissions, so the WhoIs is consumed first
  write2 = exec(:write_binary, other_id, 2_u32, false)
  sleep 100.milliseconds
  responds BACnet::Client::Message::IAm.build(
    device_message.call,
    BACnet::ObjectIdentifier.new(:device, other_id),
    1476, BACnet::SegmentationSupport::NotSupported, 389
  )

  # 2 writes and the 4 inspection reads, no further WhoIs requests
  written = [] of UInt32
  6.times do
    request = parse.call(expect_send(2.seconds))
    request.data_link.destination_address.should eq(device_vmac.hexstring)
    service = request.application.as(BACnet::ConfirmedRequest).service
    if service.write_property?
      written << BACnet::Client::Message::WriteProperty.parse(request)[:object_id].instance_number
      responds simple_ack.call(request)
    else
      service.read_property?.should be_true
      details = read_property.call(request)
      value = details[:property].object_list? ? BACnet::Object.new.set_value(0_u32) : char_string.call("Other")
      responds complex_ack.call(request, ValueObjects{value})
    end
  end
  written.sort.should eq([1_u32, 2_u32])
  write1.get.should eq(true)
  write2.get.should eq(false)

  # ===========================================================
  # an unknown device that doesn't respond is an error for the caller
  # ===========================================================

  response = exec(:write_real, 600001_u32, 1_u32, 1.0)
  parse.call(expect_send(2.seconds)).objects.map(&.as(BACnet::Object).to_u32).should eq([600001_u32, 600001_u32])
  expect_raises(PlaceOS::Driver::RemoteException) { response.get }
end
