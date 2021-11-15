require "placeos-driver"
require "promise"
require "uuid"

require "./collaboration_endpoint"
require "./collaboration_endpoint/ui_extensions"
require "./collaboration_endpoint/presentation"
require "./collaboration_endpoint/powerable"
require "./collaboration_endpoint/cameras"

class Cisco::RoomKit < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Cisco Room Kit"
  generic_name :VidConf
  tcp_port 22

  description <<-DESC
    Control of Cisco SX20 devices.

    API access requires a local user with the "admin" role to be
    created on the codec.
    DESC

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
    presets: {
      "Front Lecturn": 1,
    },
  })

  include Cisco::CollaborationEndpoint
  include Cisco::CollaborationEndpoint::UIExtensions
  include Cisco::CollaborationEndpoint::Presentation
  include Cisco::CollaborationEndpoint::Powerable
  include Cisco::CollaborationEndpoint::Cameras

  enum PresentationMode
    None
    Local
    Remote
  end

  @presentation_mode : PresentationMode = PresentationMode::None
  @calls = Hash(String, Hash(String, Enumerable::JSONComplex)).new

  def connected
    super
    schedule.in(40.seconds) { disconnect if self["calls"]?.nil? }
    @feedback_paths = ["/Event/PresentationPreviewStarted", "/Event/PresentationPreviewStopped", "/Status/Call"]
  end

  protected def connection_ready
    subscriptions.clear
    subscribe("presentation") do |_sub, state|
      if state != "null"
        # presentation is typically false or "Sending"
        if state == "false"
          self[:presentation_mode] = @presentation_mode
        else
          self[:presentation_mode] = PresentationMode::Remote
        end
      end
    end

    register_feedback "/Event/PresentationPreviewStarted" do
      self[:presentation_mode] = PresentationMode::Local
    end
    register_feedback "/Event/PresentationPreviewStopped" do
      @presentation_mode = PresentationMode::None
      self[:presentation_mode] = @presentation_mode if self[:presentation]? == false
    end

    @calls = Hash(String, Hash(String, Enumerable::JSONComplex)).new do |hash, key|
      hash[key] = {} of String => Enumerable::JSONComplex
    end
    self[:calls] = @calls
    register_feedback "/Status/Call" do |value_path, value|
      if value.is_a? Hash(String, Enumerable::JSONComplex)
        if value["Status"]? == "Idle" || value["ghost"]? == "True"
          @calls.delete value_path
        else
          @calls[value_path].merge! value
        end
        self[:calls] = @calls
      else
        logger.debug { "unexpected call status value #{value}" }
      end
    end
  end

  map_status mic_mute: "Audio Microphones Mute"
  map_status volume: "Audio Volume"
  map_status speaker_track: "Cameras SpeakerTrack"
  map_status presence_detected: "RoomAnalytics PeoplePresence"
  map_status people_count: "RoomAnalytics PeopleCount Current"
  map_status do_not_disturb: "Conference DoNotDisturb"
  map_status presentation: "Conference Presentation Mode"
  map_status peripherals: "Peripherals ConnectedDevice"
  # selfview == camera pip
  map_status selfview: "Video Selfview Mode"
  map_status selfview_fullscreen: "Video Selfview FullScreenMode"
  map_status video_input: "Video Input"
  map_status video_output: "Video Output"
  map_status video_layout: "Video Layout LayoutFamily Local"
  map_status standby: "Standby State"

  command({"Audio Microphones Mute" => :mic_mute_on})
  command({"Audio Microphones Unmute" => :mic_mute_off})
  command({"Audio Microphones ToggleMute" => :mic_mute_toggle})

  def mic_mute(state : Bool = true)
    state ? mic_mute_on : mic_mute_off
  end

  enum Toogle
    On
    Off
  end

  enum Sound
    Alert
    Bump
    Busy
    CallDisconnect
    CallInitiate
    CallWaiting
    Dial
    KeyInput
    KeyInputDelete
    KeyTone
    Nav
    NavBack
    Notification
    OK
    PresentationConnect
    Ringing
    SignIn
    SpecialInfo
    TelephoneCall
    VideoCall
    VolumeAdjust
    WakeUp
  end

  command({"Audio Sound Play" => :play_sound},
    sound: Sound,
    loop_: Toogle)
  command({"Audio Sound Stop" => :stop_sound})

  command({"Bookings List" => :bookings},
    days_: 1..365,
    day_offset_: 0..365,
    limit_: Int32,
    offset_: Int32)

  command({"Call Accept" => :call_accept}, call_id_: Int32)
  command({"Call Reject" => :call_reject}, call_id_: Int32)
  command({"Call Disconnect" => :hangup}, call_id_: Int32)
  command({"Call Hold" => :call_place_on_hold}, call_id_: Int32)
  command({"Call Resume" => :call_resume}, call_id_: Int32)

  command({"Call DTMFSend" => :dtmf_send},
    d_t_m_f_string: String,
    call_id_: 0..65534)

  enum DialProtocol
    H320
    H323
    Sip
    Spark
  end

  enum CallType
    Audio
    Video
  end

  command({"Dial" => :dial},
    number: String,
    protocol_: DialProtocol,
    call_rate_: 64..6000,
    call_type_: CallType)

  enum VideoLayout
    Equal
    PIP
  end

  command({"Video Input SetMainVideoSource" => :camera_select},
    connector_id_: 1..3,  # Source can either be specified as the
    layout_: VideoLayout, # physical connector...
    source_id_: 1..3)     # ...or the logical source ID

  enum LayoutFamily
    Auto
    Equal
    Overlay
    Prominent
    Single
  end

  enum LayoutTarget
    Local
    Remote
  end

  command({"Video Layout LayoutFamily Set" => :video_layout},
    layout_family: LayoutFamily,
    target_: LayoutTarget)

  enum PiPPosition
    CenterLeft
    CenterRight
    LowerLeft
    LowerRight
    UpperCenter
    UpperLeft
    UpperRight
  end

  enum MonitorRole
    First
    Second
    Third
    Fourth
  end

  command({"Video Selfview Set" => :selfview},
    mode_: Toogle,
    full_screen_mode_: Toogle,
    p_i_p_position_: PiPPosition,
    on_monitor_role_: MonitorRole)

  @[Security(Level::Support)]
  command({"Cameras AutoFocus Diagnostics Start" => :autofocus_diagnostics_start},
    camera_id: 1..1)

  @[Security(Level::Support)]
  command({"Cameras AutoFocus Diagnostics Stop" => :autofocus_diagnostics_stop},
    camera_id: 1..1)

  @[Security(Level::Support)]
  command({"Cameras SpeakerTrack Diagnostics Start" => :speaker_track_diagnostics_start})

  @[Security(Level::Support)]
  command({"Cameras SpeakerTrack Diagnostics Stop" => :speaker_track_diagnostics_stop})

  @[Security(Level::Support)]
  command({"Cameras SpeakerTrack Activate" => :speaker_track_activate})

  @[Security(Level::Support)]
  command({"Cameras SpeakerTrack Deactivate" => :speaker_track_deactivate})

  def speaker_track(state : Bool = true)
    state ? speaker_track_activate : speaker_track_deactivate
  end

  enum PhonebookType
    Corporate
    Local
  end

  command({"Phonebook Search" => :phonebook_search},
    search_string: String,
    phonebook_type_: PhonebookType,
    limit_: Int32,
    offset_: Int32)

  command({"UserInterface WebView Display" => :webview_display},
    url: String)

  command({"UserInterface WebView Clear" => :webview_clear})

  @[Security(Level::Support)]
  command({"SystemUnit Boot" => :reboot}, action_: PowerOff)

  # Helper methods
  # ==============

  def show_camera_pip(visible : Bool)
    mode = visible ? Toogle::On : Toogle::Off
    selfview mode: mode
  end

  def mic_mute(state : Bool = true)
    state ? mic_mute_on : mic_mute_off
  end

  def presentation_mode(value : PresentationMode)
    case value
    in .remote?
      presentation_start sending_mode: :LocalRemote
    in .local?
      @presentation_mode = PresentationMode::Local
      presentation_start sending_mode: :LocalOnly
    in .none?
      @presentation_mode = PresentationMode::None
      presentation_stop
    end
  end
end
