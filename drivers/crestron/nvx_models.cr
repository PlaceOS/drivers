require "json"

module Crestron
  # Interface for enumerating devices
  module Transmitter
  end

  module Receiver
  end

  enum AspectRatio
    MaintainAspectRatio
    StretchToFit
  end

  enum SourceType
    Audio
    Video
  end

  enum Location
    CenterLeft
    CenterRight
    Custom
    LowerLeft
    LowerRight
    UpperLeft
    UpperRight
  end

  struct OSD
    include JSON::Serializable

    @[JSON::Field(key: "IsEnabled")]
    property is_enabled : Bool?

    @[JSON::Field(key: "Location")]
    property location : String?

    @[JSON::Field(key: "XPosition")]
    property x_position : Int32? = 0

    @[JSON::Field(key: "YPosition")]
    property y_position : Int32? = 0

    @[JSON::Field(key: "Text")]
    property text : String?

    @[JSON::Field(key: "FontColor")]
    property font_color : String?

    @[JSON::Field(key: "BackgroundTransparency")]
    property background_transparency : String?

    @[JSON::Field(key: "Version")]
    property version : String? = "2.0.0"

    def initialize(@text, @is_enabled, @location, @background_transparency)
    end
  end
end
