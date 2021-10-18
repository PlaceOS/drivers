require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

class Place::Meet < PlaceOS::Driver
  generic_name :System
  descriptive_name "Meeting room logic"
  description <<-DESC
    Room level state and behaviours.

    This driver provides a high-level API for interaction with devices, systems \
    and integrations found within common workplace collaboration spaces.
    DESC

  default_settings({
    help: {
      "help-id" => {
        "title"   => "Video Conferencing",
        "content" => "markdown",
      },
    },
    tabs: [
      {
        name:          "VC",
        icon:          "conference",
        inputs:        ["VidConf_1"],
        help:          "help-id",
        controls:      "vidconf-controls",
        merge_on_join: false,
      },
    ],

    # if we want to display the selected tab on displays meant only for the presenter
    preview_outputs: ["Display_2"],
    vc_camera_in:    "switch_camera_output_id",

    # only required in joining rooms
    local_outputs: ["Display_1"],

    screens: {
      "Projector_1" => "Screen_1",
    },
  })
end

require "./router"

alias Help = Hash(String, NamedTuple(
  icon: String?,
  title: String,
  content: String))

class Tab
  include JSON::Serializable
  include JSON::Serializable::Unmapped

  def initialize(@icon, @name, @inputs, @help = nil, @controls = nil, @merge_on_join = nil)
  end

  getter icon : String
  getter name : String
  getter inputs : Array(String)

  getter help : String?

  # such as: vidconf-controls
  getter controls : String?
  getter merge_on_join : Bool?

  # For the VC controls
  getter presentation_source : String?

  def merge(tab : Tab) : Tab
    input = inputs.dup.concat(tab.inputs).uniq!
    Tab.new(@icon, @name, input, @help, @controls, @merge_on_join)
  end

  def merge!(tab : Tab) : Tab
    @inputs.concat(tab.inputs).uniq!
    self
  end
end

# This data will be stored in the tab
class QscPhone
  include JSON::Serializable

  getter number_id : String
  getter dial_id : String
  getter hangup_id : String
  getter status_id : String
  getter ringing_id : String
  getter offhook_id : String
  getter dtmf_id : String
end

class Place::Meet < PlaceOS::Driver
  include Interface::Muteable
  include Interface::Powerable
  include Router::Core

  def on_load
    on_update
  end

  @tabs : Array(Tab) = [] of Tab
  @local_tabs : Array(Tab) = [] of Tab
  @local_help : Help = Help.new

  @outputs : Array(String) = [] of String
  @local_outputs : Array(String) = [] of String
  @preview_outputs : Array(String) = [] of String
  @vc_camera_in : String? = nil

  def on_update
    self[:name] = system.display_name.presence || system.name
    self[:local_help] = @local_help = setting?(Help, :help) || Help.new
    self[:local_tabs] = @local_tabs = setting?(Array(Tab), :tabs) || [] of Tab
    self[:local_outputs] = @local_outputs = setting?(Array(String), :local_outputs) || [] of String
    self[:preview_outputs] = @preview_outputs = setting?(Array(String), :preview_outputs) || [] of String
    @vc_camera_in = setting?(String, :vc_camera_in)

    subscriptions.clear

    init_signal_routing
    init_projector_screens
    init_master_audio
    init_microphones
  end

  # link screen control to power state
  protected def init_projector_screens
    screens = setting?(Hash(String, String), :screens) || {} of String => String
    screens.each do |display, screen|
      system.subscribe(display, :power) do |_sub, power_state|
        logger.debug { "power-state changed on #{display}: #{power_state.inspect}" }
        if power_state && power_state != "null"
          logger.debug { "updating screen position: #{power_state == "true" ? "down" : "up"}" }
          mod = system[screen]
          power_state == "true" ? mod.down : mod.up
        end
      end
    end
  end

  # Sets the overall room power state.
  def power(state : Bool)
    return if state == self[:active]?
    logger.debug { "Powering #{state ? "up" : "down"}" }
    self[:active] = state

    if state
      system.all(:Camera).power true
      apply_master_audio_default
      apply_default_routes
      apply_mic_defaults

      if first_output = @tabs.first?.try &.inputs.first
        selected_input first_output
      end
    else
      system.implementing(Interface::Powerable).power false
    end
  end

  # =====================
  # System IO management
  # ====================

  @default_routes : Hash(String, String) = {} of String => String

  protected def init_signal_routing
    @default_routes = setting?(Hash(String, String), :default_routes) || {} of String => String

    logger.debug { "loading signal graph..." }
    load_siggraph
    logger.debug { "signal graph loaded" }
    update_available_tabs
    update_available_help
    update_available_outputs
  rescue error
    logger.warn(exception: error) { "failed to init signal graph" }
  end

  protected def on_siggraph_loaded(inputs, outputs)
    outputs.each &.watch { |node| on_output_change node }
  end

  protected def on_output_change(output)
    case output.source
    when Router::SignalGraph::Mute, nil
      # nothing to do here
    else
      output.proxy.power true
    end
  end

  def apply_default_routes
    @default_routes.each { |output, input| route(input, output) }
  rescue error
    logger.warn(exception: error) { "error applying default routes" }
  end

  # we want to unroute any signal going to the display
  # or if it's a direct connection, we want to mute the display
  def unroute(output : Int32 | String = 0)
    mute(true, output)
  end

  # This is the currently selected input
  # if the user selects an output then this will be routed to it
  def selected_input(name : String) : Nil
    self[:selected_input] = name
    self[:selected_tab] = @tabs.find(@tabs.first, &.inputs.includes?(name)).name

    # Perform any desired routing
    if @preview_outputs.empty?
      route(name, @outputs.first) if @outputs.size == 1
    else
      @preview_outputs.each { |output| route(name, output) }
    end
  end

  protected def all_outputs
    status(Array(String), :outputs)
  end

  protected def update_available_help
    help = @local_help.dup
    # TODO:: merge in joined room help
    self[:help] = help
  end

  protected def update_available_tabs
    tabs = @local_tabs.dup
    # TODO:: merge in joined room tabs
    self[:tabs] = @tabs = tabs
  end

  protected def update_available_outputs
    available_outputs = @local_outputs.dup
    preview_outputs = @preview_outputs.dup

    # TODO:: merge in joined room settings

    if available_outputs.empty?
      if preview_outputs.empty?
        self[:available_outputs] = @outputs = all_outputs
      else
        self[:available_outputs] = @outputs = all_outputs - preview_outputs
      end
    else
      self[:available_outputs] = @outputs = available_outputs
    end
  end

  # =======================
  # Primary volume controls
  # =======================

  class AudioFader
    include JSON::Serializable

    def initialize
    end

    getter name : String? = nil
    property level_id : String | Array(String)? = nil
    getter mute_id : String | Array(String)? = nil

    getter default_muted : Bool? = nil
    getter default_level : Float64? = nil

    getter level_index : Int32? = nil
    getter mute_index : Int32? = nil

    getter min_level : Float64 { 0.0 }
    getter max_level : Float64 { 100.0 }

    property level_feedback : String do
      id = level_id
      "fader#{id.is_a?(Array) ? id.first : id}"
    end
    property mute_feedback : String do
      id = level_id
      "fader#{id.is_a?(Array) ? id.first : id}_mute"
    end
    property module_id : String { "Mixer_1" }

    getter? level_feedback, mute_feedback

    def use_defaults?
      @module_id.nil? && (level_id.nil? || level_id.try &.empty?) && (mute_id.nil? || mute_id.try &.empty?)
    end

    def implements_volume?
      level_id == "\e"
    end
  end

  @master_audio : AudioFader? = nil

  protected def init_master_audio
    audio = setting?(AudioFader, :master_audio)
    output = @outputs.first?
    unless audio || output
      logger.warn { "no audio configuration found" }
      @master_audio = nil
      return
    end
    audio ||= AudioFader.new

    # if nothing defined then we want to use the first output
    # we might have configured default levels
    if audio.use_defaults?
      unless output
        logger.warn { "audio partially conigured, no output found" }
        return
      end

      mod = signal_node(output).ref.mod.not_nil!

      # proxy = (mod.sys == system.id ? system : system mod.sys).get mod.name, mod.idx
      audio.module_id = "#{mod.name}_#{mod.idx}"
      audio.level_feedback = "volume" unless audio.level_feedback?
      audio.mute_feedback = "mute" unless audio.mute_feedback?
      audio.level_id = "\e"
    end

    # we can subscribe to feedback before we're sure all the modules are running
    system.subscribe(audio.module_id, audio.level_feedback) do |_sub, level|
      self[:volume] = Float64.from_json(level) if level && level != "null"
    end

    system.subscribe(audio.module_id, audio.mute_feedback) do |_sub, muted|
      self[:mute] = muted == "true" if muted && muted != "null"
    end

    @master_audio = audio
  rescue error
    logger.warn(exception: error) { "failed to init master audio" }
  end

  protected def apply_master_audio_default
    audio = @master_audio
    return unless audio
    mixer = system[audio.module_id]

    case audio.default_muted
    in Bool
      set_master_mute(mixer, audio, audio.default_muted)
    in Nil
      mixer.query_mutes(audio.level_id) unless audio.implements_volume?
    end

    case audio.default_level
    in Float64
      set_master_volume(mixer, audio, audio.default_level)
    in Nil
      mixer.query_faders(audio.level_id) unless audio.implements_volume?
    end
  end

  protected def set_master_volume(mixer, audio, level)
    if level_index = audio.level_index
      mixer.fader(audio.level_id, level, level_index)
    elsif audio.implements_volume?
      mixer.volume(level)
    else
      mixer.fader(audio.level_id, level)
    end
  end

  protected def set_master_mute(mixer, audio, state)
    if mute_index = audio.mute_index
      mixer.mute(audio.level_id, state, mute_index)
    elsif audio.implements_volume?
      mixer.mute_audio(state)
    else
      mixer.mute(audio.level_id, state)
    end
  end

  # Set the volume of a signal node within the system.
  def volume(level : Int32 | Float64, input_or_output : String)
    audio = @master_audio
    if audio
      logger.debug { "setting master volume to #{level}" }
    else
      logger.debug { "no master output configured" }
      return
    end

    mixer = system[audio.module_id]
    set_master_volume(mixer, audio, level.to_f)
  end

  # Sets the mute state on a signal node within the system.
  def mute(state : Bool = true, input_or_output : Int32 | String = 0, layer : MuteLayer = MuteLayer::AudioVideo)
    audio = @master_audio
    if audio
      logger.debug { "setting master mute to #{state}" }
    else
      logger.debug { "no master output configured" }
      return
    end

    mixer = system[audio.module_id]
    set_master_mute(mixer, audio, state)
  end

  # ===================
  # Microphone Controls
  # ===================

  alias Microphone = AudioFader

  @local_mics : Array(Microphone) = [] of Microphone
  @available_mics : Array(Microphone) = [] of Microphone

  protected def init_microphones
    @local_mics = setting?(Array(Microphone), :local_microphones) || [] of Microphone
    update_available_mics
  rescue error
    logger.warn(exception: error) { "failed to init microphones" }
  end

  protected def update_available_mics
    local = @local_mics.dup

    # TODO:: merge in joined room mics

    @available_mics = local
    self[:microphones] = @available_mics.map do |mic|
      level_id = mic.level_id
      mute_id = mic.mute_id
      {
        name:           mic.name,
        level_id:       level_id.is_a?(Array) ? level_id : [level_id],
        mute_id:        mute_id.is_a?(Array) ? mute_id : [mute_id],
        level_index:    mic.level_index,
        mute_index:     mic.mute_index,
        level_feedback: mic.level_feedback,
        mute_feedback:  mic.mute_feedback,
        module_id:      mic.module_id,
      }
    end
  end

  protected def apply_mic_defaults
    @local_mics.each do |mic|
      mixer = system[mic.module_id]

      case mic.default_muted
      in Bool
        if mute_index = mic.mute_index
          mixer.mute(mic.level_id, mic.default_muted, mute_index)
        else
          mixer.mute(mic.level_id, mic.default_muted)
        end
      in Nil
        mixer.query_mutes(mic.level_id)
      end

      case mic.default_level
      in Float64
        if level_index = mic.level_index
          mixer.fader(mic.level_id, mic.default_level, level_index)
        else
          mixer.fader(mic.level_id, mic.default_level)
        end
      in Nil
        mixer.query_faders(mic.level_id)
      end
    end
  end

  # ====================
  # VC Camera Management
  # ====================

  # This is the camera input that is currently selected so we can switch between
  # different cameras
  def selected_camera(camera : String)
    self[:selected_camera] = camera
    if camera_in = @vc_camera_in
      route(camera, camera_in)
    end
  end

  def add_preset(preset : String, camera : String)
    mod, cam_index = camera_details(camera)
    system[mod].save_position preset, cam_index || 0
  end

  def remove_preset(preset : String, camera : String)
    mod, cam_index = camera_details(camera)
    system[mod].remove_position preset, cam_index || 0
  end

  alias CamDetails = NamedTuple(mod: String, index: String | Int32?)

  protected def camera_details(camera : String)
    cam = status CamDetails, "input/#{camera}"
    {cam[:mod], cam[:index]}
  end
end
