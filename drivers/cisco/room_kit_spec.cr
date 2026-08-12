require "placeos-driver/spec"
require "placeos-driver/interface/sensor"

alias Detail = PlaceOS::Driver::Interface::Sensor::Detail
alias SensorType = PlaceOS::Driver::Interface::Sensor::SensorType

# Every request the driver makes is tagged with a generated `resultId`, so
# requests are matched on their prefix and the id echoed back in the response.
# `body` is the response, without the enclosing braces or the result id.
macro exchange(request, body = "")
  %expected = {{request}}
  %data = String.new expect_send
  unless %data.starts_with?("#{%expected} | resultId=\"")
    raise "expected `#{%expected}` but received `#{%data}`"
  end

  %id = %data.split('"')[-2]
  %body = {{body}}
  responds(%body.empty? ? "{\"ResultId\":\"#{%id}\"}" : "{#{%body},\"ResultId\":\"#{%id}\"}")
end

# binding a status registers for feedback then queries the current value
macro bind_status(path, body)
  exchange "xFeedback Register /Status/" + {{path}}.tr(" ", "/")
  exchange "xStatus " + {{path}}, {{body}}
end

DriverSpecs.mock_driver "Cisco::RoomKit" do
  transmit "welcome\n*r Login successful\r\n"

  # ====
  # Connection setup
  puts "\nCONNECTION SETUP:\n=============="

  # echo is disabled on connect and again once login completes, so the codec
  # doesn't reflect our requests back at us, then the output mode is applied.
  # `xPreferences OutputMode JSON` is also written on connect, before the login
  # prompt completes, so it may or may not be captured here.
  # These are raw writes that can arrive coalesced, hence the accumulation.
  handshake = ""
  until handshake.ends_with? "xPreferences Echo Off\nxPreferences OutputMode JSON\n"
    handshake += String.new(expect_send)
  end

  # ====
  # System registration
  puts "\nSYSTEM REGISTRATION:\n=============="

  # the peripheral id is read from settings, a new one is only generated (and
  # saved) when the setting is missing
  exchange %(xCommand Peripherals Connect ID: "uuid" Name: "PlaceOS" Type: ControlSystem),
    %("CommandResponse":{"PeripheralsConnectResult":{"status":"OK"}})

  status[:ready].should eq true

  # ====
  # Config push
  puts "\nCONFIG PUSH:\n=============="

  {
    "PeopleCountOutOfCall",
    "PeoplePresenceDetector",
    "WakeupOnMotionDetection",
  }.each do |setting|
    exchange %(xConfiguration RoomAnalytics #{setting}: "On")
  end

  # ====
  # Configuration sync
  puts "\nCONFIG SYNC:\n=============="

  exchange "xFeedback Register /Configuration"

  should_send "xConfiguration *\n"
  responds %({
    "Configuration":{
      "RoomAnalytics":{
        "PeopleCountOutOfCall":{
          "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
          "Value":"On"
        },
        "PeoplePresenceDetector":{
          "valueSpaceRef":"/Valuespace/TTPAR_OnOff",
          "Value":"On"
        }
      }
    }
  })

  # ====
  # Status binding
  puts "\nSTATUS BINDING:\n=============="

  bind_status "Audio Microphones Mute",
    %("Status":{"Audio":{"Microphones":{"Mute":{"Value":"Off"}}}})

  bind_status "Audio Volume",
    %("Status":{"Audio":{"Volume":{"Value":"50"}}})

  bind_status "Cameras SpeakerTrack",
    %("Status":{"Cameras":{"SpeakerTrack":{"Availability":{"Value":"Available"},"Status":{"Value":"Active"}}}})

  bind_status "RoomAnalytics PeoplePresence",
    %("Status":{"RoomAnalytics":{"PeoplePresence":{"Value":"Yes"}}})

  bind_status "RoomAnalytics PeopleCount Current",
    %("Status":{"RoomAnalytics":{"PeopleCount":{"Current":{"Value":"4"}}}})

  bind_status "Conference DoNotDisturb",
    %("Status":{"Conference":{"DoNotDisturb":{"Value":"Inactive"}}})

  bind_status "Conference Presentation Mode",
    %("Status":{"Conference":{"Presentation":{"Mode":{"Value":"Off"}}}})

  bind_status "Peripherals ConnectedDevice",
    %("Status":{"Peripherals":{"ConnectedDevice":[{"id":"1000","Name":{"Value":"Cisco TelePresence Touch 10"},"Status":{"Value":"Connected"},"Type":{"Value":"TouchPanel"}}]}})

  bind_status "Video Selfview Mode",
    %("Status":{"Video":{"Selfview":{"Mode":{"Value":"Off"}}}})

  bind_status "Video Selfview FullScreenMode",
    %("Status":{"Video":{"Selfview":{"FullScreenMode":{"Value":"Off"}}}})

  bind_status "Video Input",
    %("Status":{"Video":{"Input":{"MainVideoSource":{"Value":"1"},"Connector":[{"id":"1","Connected":{"Value":"True"},"SourceId":{"Value":"1"},"Type":{"Value":"camera"}}]}}})

  bind_status "Video Output",
    %("Status":{"Video":{"Output":{"Connector":[{"id":"1","ConnectedDevice":{"Name":{"Value":"Display"}}}]}}})

  bind_status "Video Layout LayoutFamily Local",
    %("Status":{"Video":{"Layout":{"LayoutFamily":{"Local":{"Value":"Equal"}}}}})

  bind_status "Standby State",
    %("Status":{"Standby":{"State":{"Value":"Off"}}})

  # ====
  # Feedback registered once the connection is ready
  puts "\nCONNECTION READY:\n=============="

  exchange "xFeedback Register /Event/PresentationPreviewStarted"
  exchange "xFeedback Register /Event/PresentationPreviewStopped"
  exchange "xFeedback Register /Status/Call"

  # ====
  # Everything mapped by the connection process
  puts "\nMAPPED STATE:\n=============="

  status[:configuration].should eq({
    "/RoomAnalytics/PeopleCountOutOfCall"   => true,
    "/RoomAnalytics/PeoplePresenceDetector" => true,
  })

  status[:mic_mute].should eq false
  status[:volume].should eq 50
  status[:presence_detected].should eq "Yes"
  status[:people_count].should eq 4
  status[:do_not_disturb].should eq false
  status[:presentation].should eq false
  status[:selfview].should eq false
  status[:selfview_fullscreen].should eq false
  status[:video_layout].should eq "Equal"
  status[:standby].should eq false
  status[:calls].as_h.should be_empty

  # paths that resolve to multiple values are exposed as a hash
  status[:speaker_track].should eq({
    "Status/Cameras/SpeakerTrack/Availability" => true,
    "Status/Cameras/SpeakerTrack/Status"       => true,
  })

  status[:peripherals].should eq({
    "Status/Peripherals/ConnectedDevice/1000" => {
      "Name"   => "Cisco TelePresence Touch 10",
      "Status" => "Connected",
      "Type"   => "TouchPanel",
    },
  })

  status[:video_input].should eq({
    "Status/Video/Input/MainVideoSource" => 1,
    "Status/Video/Input/Connector/1"     => {
      "Connected" => true,
      "SourceId"  => 1,
      "Type"      => "camera",
    },
  })

  status[:video_output].should eq({
    "Status/Video/Output/Connector/1" => {
      "ConnectedDevice/Name" => "Display",
    },
  })

  # ====
  # Powerable interface
  puts "\nPOWER:\n=============="

  power = exec(:power, true)
  exchange "xCommand Standby Deactivate",
    %("CommandResponse":{"StandbyDeactivateResult":{"status":"OK"}})
  power.get
  status[:power].should eq true

  # ====
  # Commands + async feedback
  puts "\nMIC MUTE:\n=============="

  mute = exec(:mic_mute, true)
  exchange "xCommand Audio Microphones Mute",
    %("CommandResponse":{"MicrophonesMuteResult":{"status":"OK"}})
  mute.get

  # the codec pushes the state change, unrelated to any request we've made
  responds %({"Status":{"Audio":{"Microphones":{"Mute":{"Value":"On"}}}}})
  status[:mic_mute].should eq true

  # ====
  # Junk ahead of a payload is discarded rather than poisoning the buffer
  puts "\nJUNK DATA:\n=============="

  responds %(xCommand Audio Volume Set Level: 70 | resultId="echoed"\r\n{"Status":{"Audio":{"Volume":{"Value":"70"}}}})
  status[:volume].should eq 70

  # a payload split across writes is still tokenized correctly
  responds %({"Status":{"Audio":)
  responds %({"Volume":{"Value":"55"}}}})
  status[:volume].should eq 55

  # a codec that keeps echoing must not fail the request it echoed, the
  # echo is buffered until the payload it precedes arrives
  volume = exec(:xcommand, command: "Audio Volume Set", hash_args: {Level: 60})
  request = String.new expect_send
  request.starts_with?(%(xCommand Audio Volume Set Level: 60 | resultId=")).should be_true
  responds request
  responds %({"CommandResponse":{"VolumeSetResult":{"status":"OK"}},"ResultId":"#{request.split('"')[-2]}"})
  volume.get.should eq "OK"

  # ====
  # Camera interface
  puts "\nCAMERA:\n=============="

  zoom = exec(:zoom, "in")
  exchange "xCommand Camera Ramp CameraId: 1 Zoom: In ZoomSpeed: 6",
    %("CommandResponse":{"CameraRampResult":{"status":"OK"}})
  zoom.get

  halt = exec(:stop)
  exchange "xCommand Camera Ramp CameraId: 1 Pan: Stop Tilt: Stop Zoom: Stop",
    %("CommandResponse":{"CameraRampResult":{"status":"OK"}})
  halt.get

  # presets are stored on the codec and the names cached in settings
  saved = exec(:save_position, "Front Lecturn", 1)
  exchange %(xCommand Camera Preset Store CameraId: 1 PresetId: 1 Name: "Front Lecturn"),
    %("CommandResponse":{"PresetStoreResult":{"status":"OK"}})
  saved.get
  status[:camera_presets].should eq({"1" => ["Front Lecturn"]})

  recalled = exec(:recall, "Front Lecturn", 1)
  exchange "xCommand Camera Preset Activate PresetId: 1",
    %("CommandResponse":{"PresetActivateResult":{"status":"OK"}})
  recalled.get

  # ====
  # Presentation
  puts "\nPRESENTATION:\n=============="

  present = exec(:switch_to, "Input1")
  exchange "xCommand Presentation Start PresentationSource: 1 SendingMode: LocalRemote",
    %("CommandResponse":{"PresentationStartResult":{"status":"OK"}})
  present.get
  status[:presenting_input].should eq 1

  # local preview events are tracked so the source of a presentation is known
  responds %({"Event":{"PresentationPreviewStarted":{"LocalInstance":{"Value":"1"}}}})
  status[:presentation_mode].should eq "Local"

  responds %({"Event":{"PresentationPreviewStopped":{"Cause":{"Value":"userRequested"},"LocalInstance":{"Value":"1"}}}})
  status[:presentation_mode].should eq "None"

  # ====
  # Call state
  puts "\nCALLS:\n=============="

  responds %({"Status":{"Call":[{"id":"32","CallbackNumber":{"Value":"spark:1234"},"Status":{"Value":"Connected"}}]}})
  status[:calls].should eq({
    "/Status/Call/32" => {
      "CallbackNumber" => "spark:1234",
      "Status"         => "Connected",
    },
  })

  # ghosted calls are removed
  responds %({"Status":{"Call":[{"id":"32","ghost":"True"}]}})
  status[:calls].as_h.should be_empty

  # ====
  # Sensor interface
  puts "\nSENSORS:\n=============="

  sensors = Array(Detail).from_json exec(:sensors).get.to_json
  sensors.map(&.id).should eq ["people_count", "presence_detected"]
  sensors.map(&.value).should eq [4.0, 1.0]
  sensors.map(&.mac).should eq ["127.0.0.1", "127.0.0.1"]

  # unknown sensor types and devices are not matched
  Array(Detail).from_json(exec(:sensors, type: "temperature").get.to_json).should be_empty
  Array(Detail).from_json(exec(:sensors, mac: "10.0.0.1").get.to_json).should be_empty

  presence = Detail.from_json exec(:sensor, mac: "127.0.0.1", id: "presence").get.to_json
  presence.type.should eq SensorType::Presence
  presence.value.should eq 1.0

  exec(:sensor, mac: "127.0.0.1", id: "unknown").get.should eq nil
end
