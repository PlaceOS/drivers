require "placeos-driver/interface/camera"
require "bindata"

module NewTek; end

module NewTek::NDI; end

# Documentation: https://code.videolan.org/jbk/libndi
# mDNS uses port 5353 (discovery)
# NDI messaging server uses port 5960

class NewTek::NDI::PTZ < PlaceOS::Driver
  # include Interface::Powerable
  include Interface::Camera

  # Discovery Information
  generic_name :Camera
  descriptive_name "NewTek Camera NDI Protocol (experimental)"

  default_settings({
    invert_controls: false,
    presets:         {
      name: {pan: 1, tilt: 1, zoom: 1},
    },
  })

  def on_load
    # Configure the constants
    @pantilt_speed = -100..100
    self[:pan_speed] = self[:tilt_speed] = {min: -100, max: 100, stop: 0}
    self[:has_discrete_zoom] = true

    schedule.every(60.seconds) { query_status }
    schedule.in(5.seconds) do
      query_status
      info?
    end
    on_update
  end

  @invert_controls = false
  @presets = {} of String => NamedTuple(pan: Int32, tilt: Int32, zoom: Int32)

  def on_update
    self[:invert_controls] = @invert_controls = setting?(Bool, :invert_controls) || false
    @presets = setting?(Hash(String, NamedTuple(pan: Int32, tilt: Int32, zoom: Int32)), :presets) || {} of String => NamedTuple(pan: Int32, tilt: Int32, zoom: Int32)
    self[:presets] = @presets.keys
  end

  def connected
    send_text %(<ndi_version text="3" video="4" audio="3" sdk="3.5.1" platform="LINUX"/>)
    send_text %(<ndi_video quality="high"/>)
    send_text %(<ndi_enabled_streams video="false" audio="false" text="true"/>)
    send_text %(<ndi_tally on_program="false" on_preview="false"/>)
  end

  # zoom_value = 0.0 (zoomed in) ... 1.0 (zoomed out)
  # <ntk_ptz_zoom zoom="0.5"/>

  # zoom_speed = -1.0 (zoom outwards) ... +1.0 (zoom inwards) (0.0 == stopped)
  # <ntk_ptz_zoom_speed zoom_speed="0.0"/>

  # pan_value  = -1.0 (left) ... 0.0 (centered) ... +1.0 (right)
  # tilt_value = -1.0 (bottom) ... 0.0 (centered) ... +1.0 (top)
  # <ntk_ptz_pan_tilt pan="0.0" tilt="0.0"/>

  # pan_speed = -1.0 (moving right) ... 0.0 (stopped) ... +1.0 (moving left)
  # tilt_speed = -1.0 (down) ... 0.0 (stopped) ... +1.0 (moving up)
  # <ntk_ptz_pan_tilt_speed pan_speed="%f" tilt_speed="%f"/>

  # preset_no = 0 ... 99
  # <ntk_ptz_store_preset index="2"/>

  # preset_no = 0 ... 99
  # speed = 0.0(as slow as possible) ... 1.0(as fast as possible) The speed at which to move to the new preset
  # <ntk_ptz_recall_preset index="2" speed="0.8"/>

  # <ntk_ptz_focus mode="auto"/>

  # focus_value = 0.0 (focused to infinity) ... 1.0 (focused as close as possible)
  # <ntk_ptz_focus mode="manual" distance="0.5"/>

  # focus_speed = -1.0 (focus outwards) ... +1.0 (focus inwards)
  # <ntk_ptz_focus_speed mode="manual" distance="0.0"/>

  # <ntk_ptz_white_balance mode="auto"/>

  # supports: indoor, outdoor, one_shot
  # <ntk_ptz_white_balance mode="indoor"/>

  # red = 0.0(not red) ... 1.0(very red)
  # blue = 0.0(not blue) ... 1.0(very blue)
  # <ntk_ptz_white_balance mode="manual" red="0.5" blue="0.5"/>

  # <ntk_ptz_exposure mode="auto"/>

  # exposure_level = 0.0(dark) ... 1.0(light)
  # <ntk_ptz_exposure mode="manual" value="0.5"/>

  # DEPRECATED:
  # <ntk_record_stop/>

  # <ntk_record_start filename="filename_of_video.mp4"/>

  # <ntk_record_set_level level_dB="8.2"/>

  # <ntk_record_set_level level_dB="-inf"/>
end
