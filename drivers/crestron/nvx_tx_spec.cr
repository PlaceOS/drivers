require "placeos-driver/spec"
require "uri"

DriverSpecs.mock_driver "Crestron::NvxRx" do
  # Connected callback makes some queries
  should_send "/Device/DeviceSpecific/DeviceMode"
  responds %({"Device": {"DeviceSpecific": {"DeviceMode": "Transmitter"}}})

  should_send "/Device/DeviceSpecific/ActiveVideoSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveVideoSource": "Input1"}}})

  should_send "/Device/DeviceSpecific/ActiveAudioSource"
  responds %({"Device": {"DeviceSpecific": {"ActiveAudioSource": "Input1"}}})

  status[:video_source].should eq("Input1")
  status[:audio_source].should eq("Input1")

  transmit %({"Device": {"AudioVideoInputOutput": {"Inputs": [
    {"Name": "input0", "Ports": [{"IsSyncDetected": true}]},
    {"Name": "input-2", "Ports": [{"IsSyncDetected": false}]}
  ]}}})

  status["input_1_sync"].should eq(true)
  status["input_2_sync"].should eq(false)
end
