require "placeos-driver/interface/powerable"
require "placeos-driver"

class Qsc::QSysCamera < PlaceOS::Driver
  include Interface::Powerable

  # Discovery Information
  descriptive_name "QSC PTZ Camera Proxy"
  generic_name :Camera

  state : Bool = false
  @ids = Hash(String, String).new
  @mod_id : String = "Mixer"

  default_settings({
    "ids": {
      "pan_left":         "3122-RGHT-PTZ-12x72PanLeft",
      "pan_right":        "3122-RGHT-PTZ-12x72PanRight",
      "power":            "3122-RGHT-PTZ-12x72PrivacyMode",
      "preset_home_load": "3122-RGHT-PTZ-12x72Home",
      "tilt_down":        "3122-RGHT-PTZ-12x72TiltDown",
      "tilt_up":          "3122-RGHT-PTZ-12x72TiltUp",
      "zoom_in":          "3122-RGHT-PTZ-12x72ZoomIn",
      "zoom_out":         "3122-RGHT-PTZ-12x72ZoomOut",
    },
  }
  )

  def on_load
    on_update
  end

  def on_update
    @mod_id = setting?(String, :driver) || "Mixer"
    @ids = setting?(Hash(String, String), :ids) || Hash(String, String).new
    self[:no_discrete_zoom] = true
  end

  def power(state : Bool)
    camera.mute(@ids["power"], state)
  end

  def adjust_tilt(direction : String)
    case direction
    when "down"
      camera.mute(@ids["tilt_down"], true)
    when "up"
      camera.mute(@ids["tilt_up"], true)
    else # stop
      camera.mute(@ids["tilt_up"], false)
      camera.mute(@ids["tilt_down"], false)
    end
  end

  def adjust_pan(direction : String)
    case direction
    when "right"
      camera.mute(@ids["pan_right"], true)
    when "left"
      camera.mute(@ids["pan_left"], true)
    else # stop
      camera.mute(@ids["pan_right"], false)
      camera.mute(@ids["pan_left"], false)
    end
  end

  def home
    camera.trigger(@ids["preset_home_load"])
  end

  def preset(presetName : String)
    home
  end

  def zoom(direction : String)
    case direction
    when "in"
      camera.mute(@ids["zoom_in"], true)
    when "out"
      camera.mute(@ids["zoom_out"], true)
    else # stop
      camera.mute(@ids["zoom_in"], false)
      camera.mute(@ids["zoom_out"], false)
    end
  end

  protected def camera
    system[@mod_id]
  end
end
