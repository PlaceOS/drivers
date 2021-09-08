require "placeos-driver"
require "promise"
require "uuid"

require "./collaboration_endpoint"

class Cisco::RoomOS < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco Room OS"
  generic_name :RoomOS
  tcp_port 22

  description %(
    Low level driver for any Cisco Room OS device. This may be used
    if direct access is required to the device API, or a required feature
    is not provided by the device specific implementation.

    Where possible use the implementation for room device in use
    i.e. SX80, Room Kit etc.
  )

  default_settings({
    ssh: {
      username: :cisco,
      password: :cisco,
    },
    peripheral_id: "uuid",
    configuration: {
      "Audio Microphones Mute"              => {"Enabled" => "False"},
      "Audio Input Line 1 VideoAssociation" => {
        "MuteOnInactiveVideo" => "On",
        "VideoInputSource"    => 2,
      },
    },
  })

  include Cisco::CollaborationEndpoint
end
