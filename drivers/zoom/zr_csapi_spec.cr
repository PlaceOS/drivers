require "placeos-driver/spec"

DriverSpecs.mock_driver "Zoom::ZrCSAPI" do
  settings({
    enable_debug_logging: true
  })

  # Initial connection sequence
  transmit "Welcome to ZAAPI\r\n"
  should_send "echo off\r\n"
  responds "OK\r\n"
  should_send "format json\r\n"  
  responds "OK\r\n"

  exec(:bookings_list)
  should_send "zCommand Bookings List\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"BookingsListResult\",\"BookingsListResult\":{\"meetings\":[]}}\r\n"

  exec(:bookings_update)
  should_send "zCommand Bookings Update\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"BookingsUpdateResult\",\"BookingsUpdateResult\":{\"status\":\"success\"}}\r\n"

  exec(:call_disconnect)
  should_send "zCommand Call Disconnect\r\n"
  responds "{\r\n  \"Call\": {\r\n    \"Status\": \"NOT_IN_MEETING\"\r\n  },\r\n  \"Status\": {\r\n    \"message\": \"\",\r\n    \"state\": \"OK\"\r\n  },\r\n  \"Sync\": false,\r\n  \"topKey\": \"Call\",\r\n  \"type\": \"zStatus\"\r\n}"

  exec(:dial_start, "1234567890")
  should_send "zCommand Dial Start meetingNumber: 1234567890\r\n"
  responds "{\r\n  \"Call\": {\r\n    \"Status\": \"IN_MEETING\"\r\n  },\r\n  \"Status\": {\r\n    \"message\": \"\",\r\n    \"state\": \"OK\"\r\n  },\r\n  \"Sync\": false,\r\n  \"topKey\": \"Call\",\r\n  \"type\": \"zStatus\"\r\n}"
  transmit "{\r\n  \"Call\": {\r\n    \"Microphone\": {\r\n      \"Mute\": false\r\n    }\r\n  },\r\n  \"Status\": {\r\n    \"message\": \"\",\r\n    \"state\": \"OK\"\r\n  },\r\n  \"Sync\": false,\r\n  \"topKey\": \"Call\",\r\n  \"type\": \"zConfiguration\"\r\n}"
  transmit "{\r\n  \"Call\": {\r\n    \"Lock\": {\r\n      \"Enable\": false\r\n    }\r\n  },\r\n  \"Status\": {\r\n    \"message\": \"\",\r\n    \"state\": \"OK\"\r\n  },\r\n  \"Sync\": false,\r\n  \"topKey\": \"Call\",\r\n  \"type\": \"zConfiguration\"\r\n}"
  transmit  "{\r\n  \"Call\": {\r\n    \"Layout\": {\r\n      \"Size\": \"Size1\"\r\n    }\r\n  },\r\n  \"Status\": {\r\n    \"message\": \"\",\r\n    \"state\": \"OK\"\r\n  },\r\n  \"Sync\": false,\r\n  \"topKey\": \"Call\",\r\n  \"type\": \"zConfiguration\"\r\n}"
  transmit "{\r\n  \"Call\": {\r\n    \"ClosedCaption\": {\r\n      \"CanDisable\": false\r\n    }\r\n  },\r\n  \"Status\": {\r\n    \"message\": \"\",\r\n    \"state\": \"OK\"\r\n  },\r\n  \"Sync\": false,\r\n  \"topKey\": \"Call\",\r\n  \"type\": \"zStatus\"\r\n}"
  transmit "{\r\n  \"Call\": {\r\n    \"Share\": {\r\n      \"Setting\": \"MULTI_SHARE\"\r\n    }\r\n  },\r\n  \"Status\": {\r\n    \"message\": \"\",\r\n    \"state\": \"OK\"\r\n  },\r\n  \"Sync\": false,\r\n  \"topKey\": \"Call\",\r\n  \"type\": \"zConfiguration\"\r\n}" 

  exec(:dial_join_sip, "test@example.com", "SIP")
  should_send "zCommand Dial Join meetingAddress: test@example.com protocol: SIP\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"DialResult\",\"DialResult\":{\"status\":\"connecting\"}}\r\n"

  exec(:call_invite, "user@example.com")
  should_send "zCommand Call Invite user: user@example.com\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"CallResult\",\"CallResult\":{\"status\":\"invited\"}}\r\n"

  exec(:call_mute_participant, true, "12345")
  should_send "zCommand Call MuteParticipant mute: on Id: 12345\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"CallResult\",\"CallResult\":{\"status\":\"muted\"}}\r\n"

  exec(:call_mute_all, true)
  should_send "zCommand Call MuteAll mute: on\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"CallResult\",\"CallResult\":{\"status\":\"all_muted\"}}\r\n"

  exec(:call_mute_self, false)
  should_send "zCommand Audio Microphone Mute: off\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"CallResult\",\"CallResult\":{\"status\":\"unmuted\"}}\r\n"

  exec(:call_record, true)
  should_send "zCommand Call Record Enable: on\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"CallResult\",\"CallResult\":{\"status\":\"recording\"}}\r\n"

  exec(:call_make_host, "67890")
  should_send "zCommand Call MakeHost Id: 67890\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"CallResult\",\"CallResult\":{\"status\":\"host_changed\"}}\r\n"

  exec(:call_layout, "Gallery", "Large", "Top")
  should_send "zCommand Call Layout LayoutStyle: Gallery LayoutSize: Large LayoutPosition: Top\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"CallResult\",\"CallResult\":{\"status\":\"layout_changed\"}}\r\n"

  # Test sharing control methods
  exec(:sharing_start_hdmi)
  should_send "zCommand Sharing Start source: hdmi\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"SharingResult\",\"SharingResult\":{\"status\":\"sharing_started\"}}\r\n"

  exec(:sharing_stop)
  should_send "zCommand Sharing Stop\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"SharingResult\",\"SharingResult\":{\"status\":\"sharing_stopped\"}}\r\n"

  exec(:sharing_start_camera)
  should_send "zCommand Sharing Start source: camera\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"SharingResult\",\"SharingResult\":{\"status\":\"camera_sharing_started\"}}\r\n"

  # Test device testing methods
  exec(:test_microphone_start, "Device123")
  should_send "zCommand Test Microphone Start Id: Device123\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"TestResult\",\"TestResult\":{\"status\":\"test_started\"}}\r\n"

  exec(:test_microphone_stop)
  should_send "zCommand Test Microphone Stop\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"TestResult\",\"TestResult\":{\"status\":\"test_stopped\"}}\r\n"

  exec(:test_speakers_start)
  should_send "zCommand Test Speakers Start\r\n"
  responds "{\"type\":\"zCommand\",\"topKey\":\"TestResult\",\"TestResult\":{\"status\":\"test_started\"}}\r\n"

  # Test zStatus methods
  exec(:system_unit?)
  should_send "zStatus SystemUnit\r\n"
  responds "{\"type\":\"zStatus\",\"topKey\":\"SystemUnit\",\"SystemUnit\":{\"platform\":\"windows\",\"version\":\"5.8.0\"}}\r\n"

  exec(:call_status)
  should_send "zStatus Call Status\r\n"
  responds "{\"type\":\"zStatus\",\"topKey\":\"Call\",\"Call\":{\"Status\":\"NOT_IN_MEETING\"}}\r\n"

  exec(:capabilities)
  should_send "zStatus Capabilities\r\n"
  responds "{\"type\":\"zStatus\",\"topKey\":\"Capabilities\",\"Capabilities\":{\"HardwareEncryption\":true}}\r\n"

  # Test zConfiguration methods
  exec(:config_audio_volume, 75)
  should_send "zConfiguration Audio Output volume: 75\r\n"
  responds "{\"type\":\"zConfiguration\",\"topKey\":\"Audio\",\"Audio\":{\"Output\":{\"volume\":75}}}\r\n"

  exec(:config_audio_volume)
  should_send "zConfiguration Audio Output volume\r\n"
  responds "{\"type\":\"zConfiguration\",\"topKey\":\"Audio\",\"Audio\":{\"Output\":{\"volume\":50}}}\r\n"

  exec(:config_video_camera, "Camera001")
  should_send "zConfiguration Video Camera selectedDevice: Camera001\r\n"
  responds "{\"type\":\"zConfiguration\",\"topKey\":\"Video\",\"Video\":{\"Camera\":{\"selectedDevice\":\"Camera001\"}}}\r\n"

  exec(:config_call_mute_on_entry, true)
  should_send "zConfiguration Call muteUserOnEntry: on\r\n"
  responds "{\"type\":\"zConfiguration\",\"topKey\":\"Call\",\"Call\":{\"muteUserOnEntry\":true}}\r\n"

  # Check that status values are properly set
  status[:system_unit]?.should_not be_nil
  status[:call_status]?.should_not be_nil
  status[:capabilities]?.should_not be_nil
  status[:audio_config]?.should_not be_nil
  status[:video_config]?.should_not be_nil
  status[:call_config]?.should_not be_nil
end
