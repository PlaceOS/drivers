require "placeos-driver/spec"
require "uri"

DriverSpecs.mock_driver "Crestron::NvxRx" do
  # Connected callback makes some queries
  should_send "/Device/DeviceSpecific/DeviceMode"
  responds %({"Device": {"DeviceSpecific": {"DeviceMode": "Transmitter"}}})

  should_send "/Device/Localization/Name"
  responds %({"Device": {"Localization": {"Name": "pc-in-rack"}}})

  should_send "/Device/NaxAudio/NaxTx/NaxTxStreams/Stream01/SessionNameStatus"
  responds %({"Device": {"NaxAudio": {"NaxTx": {"NaxTxStreams": {"Stream01": {"SessionNameStatus": "pc-in-rack"}}}}}})

  should_send "/Device/StreamTransmit/Streams"
  responds %({"Device": {"StreamTransmit": {"Streams": [{"MulticastAddress": "192.168.0.2"}]}}})

  should_send "/Device/DeviceSpecific/ActiveVideoSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveVideoSource": "Input1"}}})

  should_send "/Device/DeviceSpecific/ActiveAudioSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveAudioSource": "Input1"}}})

  status[:stream_name].should eq("pc-in-rack")
  status[:multicast_address].should eq("192.168.0.2")
  status[:audio_source].should eq("Input1")
  status[:audio_source].should eq("Input1")

  transmit %({"Device": {"AudioVideoInputOutput": {"Inputs": [
    {"Name": "input0", "Ports": [{"IsSyncDetected": true}]},
    {"Name": "input-2", "Ports": [{"IsSyncDetected": false}]}
  ]}}}).gsub(/\s/, "")

  status["input_1_sync"].should eq(true)
  status["input_2_sync"].should eq(false)
end
