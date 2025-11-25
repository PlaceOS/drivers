require "json"

module Catchbox
  struct ApiRequest
    include JSON::Serializable

    property rx : HubMessage?
    property tx1 : MicrophoneMessage?
    property tx2 : MicrophoneMessage?
    property tx3 : MicrophoneMessage?
    property tx4 : MicrophoneMessage?
  end

  struct ApiResponse
    include JSON::Serializable

    property rx : HubMessage?
    property tx1 : MicrophoneMessage?
    property tx2 : MicrophoneMessage?
    property tx3 : MicrophoneMessage?
    property tx4 : MicrophoneMessage?
    property error : Int32?
  end

  struct HubMessage
    include JSON::Serializable

    property network : Network?
    property device : Device?
    property audio : Audio?
    property settings : Settings?
  end

  struct MicrophoneMessage
    include JSON::Serializable

    property feature : Feature?
    property device : Device?
  end

  struct Network
    include JSON::Serializable

    property mac : String?
    property ip_mode : Int32?
    property ip_address : String?
    property subnet : String?
    property gateway : String?
    property reboot : Int32?
  end

  struct Device
    include JSON::Serializable

    property name : String?
    property device_type : String?
    property firmware_info : String?
    property serial : String?
    property battery : Int32?
    property mic1_link_state : Int32?
    property mic2_link_state : Int32?
    property mic3_link_state : Int32?
    property mic4_link_state : Int32?
    property reset : Int32?
    property reset_to_default : Int32?
    property rssi : Int32?
    property rf_power : Int32?
    property flex_mode : Int32?
    property usb_device_mode : Int32?
    property read_only_mode : Int32?
    property pairing : Int32?
  end

  struct Audio
    include JSON::Serializable

    property input : AudioInput?
  end

  struct Settings
    include JSON::Serializable

    property input : AudioInput?
  end

  struct Feature
    include JSON::Serializable

    property mute_button_enable : Int32?
    property mute_at_pickup_enable : Int32?
    property out_of_range_alarm_enable : Int32?
    property power_saving_enable : Int32?
    property stealth_mode_enable : Int32?
  end

  struct AudioInput
    include JSON::Serializable

    property mic1 : AudioState?
    property mic2 : AudioState?
    property mic3 : AudioState?
    property mic4 : AudioState?
    property usb : AudioState?
    property aux : AudioState?
  end

  struct AudioState
    include JSON::Serializable

    property gain : Int32?
    property mute : Int32?
    property activity : Int32?
  end

  enum LinkState
    Disconnected
    Connected
    Pairing
    Charging
  end
end
