require "placeos-driver"
require "placeos-driver/interface/chat_functions"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/lighting"
require "./meet/qsc_phone_dialing"
require "./meet/help"
require "./meet/tab"
require "./router/core"

class Place::Meet < PlaceOS::Driver
  include Interface::ChatFunctions
  include Interface::Muteable
  include Interface::Powerable
  include Router::Core

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
    preview_outputs:        ["Display_2"],
    vc_camera_in:           "switch_camera_output_id",
    join_lockout_secondary: true,
    unjoin_on_shutdown:     false,
    mute_on_unlink:         true,

    # only required in joining rooms
    local_outputs: ["Display_1"],

    screens: {
      "Projector_1" => "Screen_1",
    },

    # change to false if there is a joining flag
    lighting_independent: true,
    lighting_area:        {
      # see interface/lighting for options
      id:   34,
      join: 0x01,
    },
    lighting_scenes: [
      {
        name:    "Full",
        id:      1,
        icon:    "lightbulb",
        opacity: 1.0,
      },
      {
        name:    "Medium",
        id:      2,
        icon:    "lightbulb",
        opacity: 0.5,
      },
      {
        name:    "Off",
        id:      3,
        icon:    "lightbulb_outline",
        opacity: 0.8,
      },
    ],
  })

  # =========================
  # The LLM Interface
  # =========================

  getter capabilities : String do
    String.build do |str|
      str << "provides meeting room audio visual control such as controlling video source to be presented\n"
      str << "check for available inputs and outputs before switching to present a source to a display.\n"
      str << "output volume and microphone fader controls are floats between 0.0 to 100.0\n"
      str << "query output volume to change it by a relative amount, if asked to increase or decrease volume, change it by 10.0\n"
      str << "audio can be muted and you unroute video to blank displays.\n"
      str << "you can also shutdown, startup, power off, power on, start or end the meeting using the set_power_state function available in this capability.\n"
      str << "some rooms may have lighting control, make sure to check what levels are available before changing state\n"
      str << "some rooms may have accessories such as blinds or projector screen controls. Check for available accessories when asked about something not explicitly controllable\n"
    end
  end

  EXT_INIT  = [] of Symbol
  EXT_POWER = [] of Symbol

  # extensions:
  include Place::QSCPhoneDialing

  def on_load
    system.load_complete do
      init_previous_join_state
      on_update
    end
  end

  @tabs : Array(Tab) = [] of Tab
  getter local_help : Help = Help.new
  getter local_tabs : Array(Tab) = [] of Tab

  @outputs : Array(String) = [] of String
  getter linked_outputs = {} of String => Hash(String, String)
  getter local_outputs : Array(String) = [] of String

  @preview_outputs : Array(String) = [] of String
  getter local_preview_outputs : Array(String) = [] of String

  @shutdown_devices : Array(String)? = nil
  @local_vidconf : String = "VidConf_1"
  @ignore_update : Int64 = 0_i64
  @unjoin_on_shutdown : Bool? = nil
  @mute_on_unlink : Bool = true

  # core includes: 'current_routes' hash
  # but we override it here for LLM integration
  @[Description("obtain the current routes, output => input")]
  getter current_routes : Hash(String, String?) = {} of String => String?

  def on_update
    return if (Time.utc.to_unix - @ignore_update) < 3

    self[:name] = system.display_name.presence || system.name
    self[:local_help] = @local_help = setting?(Help, :help) || Help.new
    self[:local_tabs] = @local_tabs = setting?(Array(Tab), :tabs) || [] of Tab
    self[:local_outputs] = @local_outputs = setting?(Array(String), :local_outputs) || [] of String
    self[:local_preview_outputs] = @local_preview_outputs = setting?(Array(String), :preview_outputs) || [] of String
    self[:voice_control] = setting?(Bool, :voice_control) || false
    @shutdown_devices = setting?(Array(String), :shutdown_devices)
    @local_vidconf = setting?(String, :local_vidconf) || "VidConf_1"
    @unjoin_on_shutdown = setting?(Bool, :unjoin_on_shutdown)
    @mute_on_unlink = setting?(Bool, :mute_on_unlink) || false

    @join_lock.synchronize do
      subscriptions.clear

      reset_remote_cache
      init_signal_routing
      init_projector_screens
      init_master_audio
      init_microphones
      init_accessories
      init_lighting
      init_vidconf
      init_joining
    end

    # initialize all the extentsions
    {% for func in EXT_INIT %}
      begin
        {{func.id}}
      rescue error
        logger.warn(exception: error) { "error in init function: #{ {{func.id.stringify}} }" }
      end
    {% end %}
  end

  # link screen control to power state
  protected def init_projector_screens
    screens = setting?(Hash(String, String), :screens) || {} of String => String

    subscribe(:active) do |_sub, active_state|
      if active_state == "true"
        sys = system
        screens.each do |display, screen|
          system[screen].down if sys[display][:power] == true
        end
      end
    end

    screens.each do |display, screen|
      system.subscribe(display, :power) do |_sub, power_state|
        logger.debug { "power-state changed on #{display}: #{power_state.inspect}" }
        if power_state == "false"
          logger.debug { "updating screen position: up" }
          system[screen].up
        elsif power_state == "true"
          logger.debug { "updating screen position: down" }
          system[screen].down
        end
      end
    end
  end

  @[Description("power on or off the meeting room. Send true for power on (startup) or false for power off (shutdown)")]
  def set_power_state(state : Bool)
    power state
  end

  # Sets the overall room power state.
  def power(state : Bool, unlink : Bool = false)
    return if state == status?(Bool, :active)
    logger.debug { "Powering #{state ? "up" : "down"}" }
    self[:active] = state
    unlink = @unjoin_on_shutdown.nil? ? unlink : !!@unjoin_on_shutdown

    remotes_before = remote_rooms
    sys = system

    if state
      apply_master_audio_default
      apply_camera_defaults
      apply_default_routes
      apply_mic_defaults

      if first_output = @tabs.first?.try &.inputs.first
        selected_input first_output
      end
    else
      unlink_systems if unlink

      @local_outputs.each { |output| unroute(output) }
      @local_preview_outputs.each { |output| unroute(output) }

      if devices = @shutdown_devices
        devices.each { |device| sys[device].power false }
      else
        sys.implementing(Interface::Powerable).power false
      end
      sys[@local_vidconf].hangup if sys.exists?(@local_vidconf)
    end

    remotes_before.each { |room| room.power(state, unlink) }

    # perform power state actions
    {% for func in EXT_POWER %}
      begin
        {{func.id}}(state, unlink)
      rescue error
        logger.warn(exception: error) { "error in power state function: #{ {{func.id.stringify}} }" }
      end
    {% end %}

    state
  end

  @[Description("query the system power state?")]
  def power? : Bool
    status?(Bool, :active) || false
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
    @default_routes.each { |output, input| route_signal(input, output) }
  rescue error
    logger.warn(exception: error) { "error applying default routes" }
  end

  @[Description("available inputs and outputs. Route using id keys")]
  def inputs_and_outputs
    inps = all_inputs
    outs = all_outputs

    results = [] of NamedTuple(type: Symbol, name: String, id: String)
    inps.each do |input|
      name = status?(NamedTuple(name: String), "input/#{input}")
      if name
        results << {type: :input, name: name[:name], id: input}
      end
    end
    outs.each do |output|
      name = status?(NamedTuple(name: String), "output/#{output}")
      if name
        results << {type: :output, name: name[:name], id: output}
      end
    end
    results
  end

  @[Description("route to present an input to an output / display. Don't guess, look up available input and output ids")]
  def route_input(input_id : String, output_id : String)
    # obtain input ID
    keys = all_inputs
    hash = keys.each_with_object({} of String => String) do |input, memo|
      memo[input.downcase] = input
    end
    input_actual = hash[input_id.downcase]?
    raise "invalid input #{input_id}, must be one of #{keys.join(", ")}" unless input_actual

    # obtain output ID
    keys = all_outputs
    hash = keys.each_with_object({} of String => String) do |output, memo|
      memo[output.downcase] = output
    end
    output_actual = hash[output_id.downcase]?
    raise "invalid output #{output_id}, must be one of: #{keys.join(", ")}" unless output_actual

    power true
    selected_input(input_actual)
    route(input_actual, output_actual)
  end

  def route(input : String, output : String, max_dist : Int32? = nil, simulate : Bool = false, follow_additional_routes : Bool = true)
    route_signal(input, output, max_dist, simulate, follow_additional_routes)

    if links = @linked_outputs[output]?
      links.each { |_sys_id, remote_out| route_signal(input, remote_out, max_dist, simulate, follow_additional_routes) }
    end

    if !simulate
      remote_systems.each do |remote_system|
        room = remote_system.room_logic
        sys_id = remote_system.system_id
        if links = @linked_outputs[output]?
          if remote_out = links[sys_id]?
            room.route(input, remote_out, max_dist, true, follow_additional_routes)
          end
        end
      end
    end
  end

  # we want to unroute any signal going to the display
  # or if it's a direct connection, we want to mute the display.
  @[Description("blank a display / output, sometimes called a video mute")]
  def unroute(output : String)
    route("MUTE", output)
  rescue error
    logger.debug(exception: error) { "failed to unroute #{output}" }
  end

  # This is the currently selected input
  # if the user selects an output then this will be routed to it
  def selected_input(name : String, simulate : Bool = false) : Nil
    selected_tab = @tabs.find(&.inputs.includes?(name)).try &.name
    if selected_tab || !simulate
      self[:selected_input] = name
      self[:selected_tab] = selected_tab || @tabs.first

      # ensure inputs are powered on (mostly to bring VC out of standby)
      sys = system
      if sys.exists? name
        mod = sys[name]
        mod.power(true) if mod.implements? Interface::Powerable
      end
    end

    # Perform any desired routing
    if !simulate
      if @preview_outputs.empty?
        route_signal(name, @outputs.first) if @outputs.size == 1
      else
        @preview_outputs.each { |output| route_signal(name, output) }
      end

      remote_rooms.each { |room| room.selected_input(name, true) }
    end
  end

  protected def all_outputs
    status(Array(String), :outputs)
  end

  protected def all_inputs
    status(Array(String), :inputs)
  end

  protected def update_available_help
    help = @local_help.dup

    # merge in joined room help
    remote_rooms.each do |room|
      help.merge! Help.from_json(room.local_help.get.to_json)
    end

    self[:help] = help
  end

  protected def update_available_tabs
    tabs = @local_tabs.dup.map(&.clone)

    # merge in joined room tabs
    remote_rooms.each do |room|
      remote_tabs = Array(Tab).from_json(room.local_tabs.get.to_json)
      remote_tabs.each do |remote_tab|
        next if remote_tab.merge_on_join == false

        if local_tab = tabs.find { |loc_tab| loc_tab.name == remote_tab.name }
          local_tab.merge!(remote_tab)
        else
          tabs << remote_tab
        end
      end
    end

    self[:tabs] = @tabs = tabs
  end

  protected def update_available_outputs
    available_outputs = @local_outputs.dup
    seen_outputs = @local_outputs.dup

    preview_outputs = @local_preview_outputs.dup

    new_linked_outputs = Hash(String, Hash(String, String)).new { |hash, key| hash[key] = {} of String => String }

    # Grab the join mode if any
    if join_mode = @join_modes[@join_selected]?
      # merge in joined room settings
      remote_systems.each do |remote_system|
        room = remote_system.room_logic
        remote_system_id = remote_system.system_id
        preview_outputs.concat room.local_preview_outputs.get.as_a.map(&.as_s)

        # merge in outputs from remote rooms
        remote_outputs = room.local_outputs.get.as_a.map(&.as_s)
        remote_outputs.each_with_index do |remote_out, index|
          if join_mode.merge_outputs? && (local_out = available_outputs[index]?)
            new_linked_outputs[local_out][remote_system_id] = remote_out
          end

          next if seen_outputs.includes?(remote_out)
          available_outputs << remote_out
          seen_outputs << remote_out
        end
      end
    end

    @linked_outputs = new_linked_outputs
    self[:preview_outputs] = @preview_outputs = preview_outputs

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
    getter mute_id : String | Array(String)? { level_id }

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
      id = mute_id || level_id
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
      audio.mute_feedback = "audio_mute" unless audio.mute_feedback?
      audio.level_id = "\e"
    end

    # we can subscribe to feedback before we're sure all the modules are running
    system.subscribe(audio.module_id, audio.level_feedback) do |_sub, level|
      raw_level = Float64.from_json(level) if level && level != "null"
      if raw_level
        range = audio.min_level..audio.max_level
        vol_percent = ((raw_level.to_f - range.begin.to_f) / (range.end - range.begin)) * 100.0
        self[:volume] = vol_percent
      end
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
      mixer.mute(audio.mute_id, state)
    end
  end

  @[Description("change the room volume")]
  def set_volume(level : Int32 | Float64)
    power true
    if level.zero?
      audio_mute true
      "audio was muted"
    else
      audio_mute false
      volume level, ""
      "volume set to #{level.to_f.clamp(0.0, 100.0)}"
    end
  end

  @[Description("query the current volume, useful to know when asked to change the volume relatively")]
  def volume?
    status?(Float64, :volume) || 0.0
  end

  @[Description("mute or unmute the room audio")]
  def audio_mute(state : Bool)
    mute state
    state ? "audio is muted" : "audio is unmuted"
  end

  @[Description("check if the room audio is muted")]
  def audio_muted?
    status?(Bool, :mute) || false
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

    level = level.to_f.clamp(0.0, 100.0)
    percentage = level / 100.0
    range = audio.min_level..audio.max_level

    # adjust into range
    level_actual = percentage * (range.end - range.begin)
    level_actual = (level_actual + range.begin.to_f).round(1)

    mixer = system[audio.module_id]
    set_master_volume(mixer, audio, level_actual)
  end

  # Sets the mute state on a signal node within the system.
  def mute(state : Bool = true, index : Int32 | String = 0, layer : MuteLayer = MuteLayer::AudioVideo)
    input_or_output = index
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

  # =================
  # Lighting Controls
  # =================

  alias LightingArea = Interface::Lighting::Area
  alias LightingScene = NamedTuple(name: String, id: UInt32, icon: String, opacity: Float64)

  DEFAULT_LIGHT_MOD = "Lighting_1"

  getter local_lighting_area : LightingArea? = nil
  getter lighting_independent : Bool = false
  @light_area : LightingArea? = nil
  @light_scenes : Hash(String, UInt32) = {} of String => UInt32
  @light_module : String = DEFAULT_LIGHT_MOD

  @light_subscription : PlaceOS::Driver::Subscriptions::Subscription? = nil

  protected def init_lighting
    # deal with `false`
    lights_independent = setting?(Bool, :lighting_independent)
    @lighting_independent = lights_independent.nil? ? true : lights_independent
    @light_area = @local_lighting_area = setting?(LightingArea, :lighting_area)
    light_scenes = setting?(Array(LightingScene), :lighting_scenes)
    @light_module = setting?(String, :lighting_module) || DEFAULT_LIGHT_MOD

    local_scenes = {} of String => UInt32

    light_scenes.try(&.each { |scene| local_scenes[scene[:name].downcase] = scene[:id] })
    @light_scenes = local_scenes
    self[:lighting_scenes] = light_scenes

    @light_subscription = nil
    update_available_lighting
  end

  protected def update_available_lighting
    if sub = @light_subscription
      subscriptions.unsubscribe sub
      @light_subscription = nil
    end

    return if @light_scenes.empty?

    # Check current join state
    if light_area = @local_lighting_area
      unless lighting_independent
        # merge in joined room mics
        remote_rooms.each do |room|
          begin
            remote_area = LightingArea.from_json(room.local_lighting_area.get.to_json)
            light_area = light_area.join_with(remote_area)
          rescue error
            logger.warn(exception: error) { "ignoring lighting config in room #{room.name} (#{room.id})" }
          end
        end
      end

      # perform lighting linking if it's available
      @light_area = light_area
      lighting = system[@light_module]
      if lighting.implements? "link_area"
        if remote_rooms.empty?
          lighting.unlink_area light_area.id
        else
          lighting.link_area light_area.id, light_area.join
        end
      end
    end

    @light_subscription = system.subscribe(@light_module, @light_area.to_s) do |_sub, scene|
      self[:lighting_scene] = scene.to_i if scene && scene != "null"
    end
  end

  def select_lighting_scene(scene : String, push_to_remotes : Bool = true)
    scene_id = @light_scenes[scene.downcase]?
    raise ArgumentError.new("invalid scene '#{scene}', valid scenes are: #{@light_scenes.keys.join(", ")}") unless scene_id

    system[@light_module].set_lighting_scene(scene_id, @light_area)

    # We are not using a join mode, so we need to set the lighting scene in joined rooms
    if push_to_remotes && lighting_independent
      remote_rooms.each { |room| room.select_lighting_scene(scene, false) }
    end
  end

  @[Description("returns the list of available lighting scenes")]
  def lighting_scenes
    scenes = status?(Array(NamedTuple(name: String)), :lighting_scenes)
    raise "no lighting control available" unless scenes
    scenes.map { |scene| scene[:name].downcase }
  end

  @[Description("query the current lighting scene")]
  def lighting_scene?
    scenes = status?(Array(NamedTuple(name: String, id: Int32)), :lighting_scenes)
    raise "no lighting control available" unless scenes
    current = status?(Int32, :lighting_scene)
    scene = scenes.find { |available| available[:id] == current }
    scene ? "current lighting scene: #{scene[:name]}" : "lights in unknown state"
  end

  @[Description("set a new lighting scene. Remember to list available lighting scenes before calling")]
  def set_lighting_scene(scene : String)
    scenes = lighting_scenes
    raise "invalid scene #{scene}, must be one of: #{scenes.join(", ")}" unless scenes.includes?(scene.downcase)
    select_lighting_scene scene
    "current lighting scene: #{scene}"
  end

  # ================
  # Room Accessories
  # ================

  struct Accessory
    include JSON::Serializable

    struct Control
      include JSON::Serializable

      getter name : String
      getter icon : String
      getter function_name : String
      getter arguments : Array(JSON::Any)
    end

    getter name : String
    getter module : String
    getter controls : Array(Control)
  end

  getter local_accessories : Array(Accessory) = [] of Accessory

  protected def init_accessories
    @local_accessories = setting?(Array(Accessory), :room_accessories) || [] of Accessory
    update_available_accessories
  end

  protected def update_available_accessories
    accessories = @local_accessories.dup
    remote_rooms.each do |room|
      accessories.concat Array(Accessory).from_json(room.local_accessories.get.to_json)
    end
    self[:room_accessories] = accessories
  end

  # ===================
  # Microphone Controls
  # ===================

  alias Microphone = AudioFader

  getter local_mics : Array(Microphone) = [] of Microphone
  @available_mics : Array(Microphone) = [] of Microphone

  protected def init_microphones
    @local_mics = setting?(Array(Microphone), :local_microphones) || [] of Microphone
    update_available_mics
  rescue error
    logger.warn(exception: error) { "failed to init microphones" }
  end

  protected def update_available_mics
    local = @local_mics.dup

    # merge in joined room mics
    remote_rooms.each do |room|
      local.concat Array(Microphone).from_json(room.local_mics.get.to_json)
    end

    # expose the details to the UI
    @available_mics = local
    self[:microphones] = @available_mics.map do |mic|
      level_id = mic.level_id
      mute_id = mic.mute_id
      level_array = level_id.is_a?(Array) ? level_id : [level_id]
      mute_array = mute_id.is_a?(Array) ? mute_id : [mute_id]

      {
        name:           mic.name,
        level_id:       level_array.compact,
        mute_id:        mute_array.compact,
        level_index:    mic.level_index,
        mute_index:     mic.mute_index,
        level_feedback: mic.level_feedback,
        mute_feedback:  mic.mute_feedback,
        module_id:      mic.module_id,
        min_level:      mic.min_level,
        max_level:      mic.max_level,
      }
    end
  end

  protected def apply_mic_defaults
    @local_mics.each do |mic|
      mixer = system[mic.module_id]

      case mic.default_muted
      in Bool
        if mute_index = mic.mute_index
          mixer.mute(mic.mute_id, mic.default_muted, mute_index)
        else
          mixer.mute(mic.mute_id, mic.default_muted)
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

  # level is a percentage 0.0->100.0
  def set_microphone(level : Float64, mute : Bool = false)
    @local_mics.each do |mic|
      mixer = system[mic.module_id]

      if level_index = mic.level_index
        mixer.fader(mic.level_id, level, level_index)
      else
        mixer.fader(mic.level_id, level)
      end

      if mute_index = mic.mute_index
        mixer.mute(mic.level_id, mute, mute_index)
      else
        mixer.mute(mic.level_id, mute)
      end
    end
  end

  # ====================
  # VC Camera Management
  # ====================

  class CamDetails
    include JSON::Serializable

    getter mod : String
    getter index : String | Int32? # if multiple cams on the one device (VidConf mod for instance)
    getter vc_camera_input : String | Int32?
  end

  @vc_camera_in : String | Array(String)? = nil
  protected getter vc_camera_module : String { "Camera" }

  def init_vidconf
    @vc_camera_in = setting?(String | Array(String), :vc_camera_in)
    @vc_camera_module = setting?(String, :vc_camera_module)
  end

  # run on system power on
  def apply_camera_defaults
    system.all(vc_camera_module).power true
  end

  # This is the camera input that is currently selected so we can switch between
  # different cameras
  def selected_camera(camera : String)
    self[:selected_camera] = camera

    cam = camera_details(camera)
    system[cam.mod].power(true)

    # route the camera
    case camera_in = @vc_camera_in
    in String
      route_signal(camera, camera_in)
    in Array(String)
      camera_in.each { |cin| route_signal(camera, cin) }
    in Nil
    end

    # switch to the correct VC input
    if camera_vc_in = cam.vc_camera_input
      system[@local_vidconf].camera_select(camera_vc_in)
    end
  end

  def add_preset(preset : String, camera : String)
    cam = camera_details(camera)
    system[cam.mod].save_position preset, cam.index || 0
  end

  def remove_preset(preset : String, camera : String)
    cam = camera_details(camera)
    system[cam.mod].remove_position preset, cam.index || 0
  end

  protected def camera_details(camera : String)
    status CamDetails, "input/#{camera}"
  end

  # =========================
  # Room Joining Coordination
  # =========================
  enum JoinType
    # only rooms part of the join need to be notified
    Independent

    # even rooms not part of the join, need to be notified
    FullyAware
  end

  class JoinAction
    include JSON::Serializable

    getter module_id : String
    getter function_name : String
    getter arguments : Array(JSON::Any) { [] of JSON::Any }
    getter named_args : Hash(String, JSON::Any) { {} of String => JSON::Any }
    getter? master_only : Bool { true }
  end

  class JoinDetail
    include JSON::Serializable

    getter id : String
    getter name : String
    getter room_ids : Array(String)
    getter join_actions : Array(JoinAction) { [] of JoinAction }

    # Do we want to merge the outputs (all outputs on all screens)
    # or do we want them as seperate displays
    getter? merge_outputs : Bool = true

    @[JSON::Field(ignore: true)]
    getter? linked : Bool { !room_ids.empty? }
  end

  class JoinSetting
    include JSON::Serializable

    getter type : JoinType { JoinType::Independent }
    getter lock_remote : Bool { false }
    getter modes : Array(JoinDetail)

    @[JSON::Field(ignore: true)]
    getter all_rooms : Set(String) do
      modes.reduce(Set(String).new) { |rooms, mode| rooms.concat(mode.room_ids) }
    end
  end

  @join_lock : Mutex = Mutex.new(:reentrant)
  @join_selected : String? = nil
  @join_confirmed : Bool = false
  @join_settings : JoinSetting? = nil
  @join_modes : Hash(String, JoinDetail) = {} of String => JoinDetail

  # this is called on_load, before settings are loaded to setup any previous state
  protected def init_previous_join_state
    init_joining
    master = setting?(Bool, :join_master)
    self[:join_master] = @join_master = master.nil? ? true : master
    self[:joined] = @join_selected = setting?(String, :join_selected)
    self[:join_confirmed] = @join_confirmed = true

    if @join_modes[@join_selected]?.nil?
      self[:join_master] = @join_master = true
      self[:joined] = @join_selected = nil
      self[:join_confirmed] = @join_confirmed = true
    end
  end

  protected def init_joining
    @join_settings = join_settings = setting?(JoinSetting, :join_modes)
    join_lookup = {} of String => JoinDetail
    join_settings.try &.modes.each { |mode| join_lookup[mode.id] = mode }
    self[:join_modes] = @join_modes = join_lookup

    self[:join_lockout_secondary] = setting?(Bool, :join_lockout_secondary) || false
    self[:join_hide_button] = setting?(Bool, :join_hide_button) || false
  end

  def join_mode(mode_id : String, master : Bool = true)
    mode = @join_modes[mode_id]
    old_mode = @join_modes[@join_selected]? if @join_selected
    join_settings = @join_settings.not_nil!
    this_room = config.control_system.not_nil!.id

    begin
      @join_lock.synchronize do
        # check this room is included in the join
        if master
          notify_rooms = join_settings.type.fully_aware? ? join_settings.all_rooms : mode.room_ids
          if mode.linked?
            raise "unable to perform join from this system" unless notify_rooms.includes?(this_room)
          end

          @join_selected = mode.id
          @join_master = true

          # unlink independent rooms
          if old_mode && old_mode.linked? && join_settings.type.independent?
            unlink(old_mode.room_ids - mode.room_ids) # find the rooms not incuded in this join
          end

          # unlink fully aware systems (empty array for independent rooms, unlinked above)
          return unlink(notify_rooms) if !mode.linked?

          reset_remote_cache
          self[:join_confirmed] = @join_confirmed = false

          notify_rooms.each do |room_id|
            next if room_id == this_room
            system(room_id).get("System", 1).join_mode(mode_id, master: false).get
          end
          persist_join_state

          self[:join_master] = master
          self[:joined] = @join_selected
          self[:join_confirmed] = @join_confirmed = true
        else
          @join_selected = mode.id
          @join_master = false
          reset_remote_cache

          persist_join_state

          self[:join_master] = master
          self[:joined] = mode.id
          self[:join_confirmed] = @join_confirmed = true
        end
      end
    ensure
      update_available_ui

      # perform the custom actions
      mode.join_actions.each do |action|
        if master || !action.master_only?
          # dynamic function invocation
          system[action.module_id].__send__(action.function_name, action.arguments, action.named_args)
        end
      end

      # recall the first lighting preset
      if !@light_scenes.empty? && master
        select_lighting_scene(@light_scenes.keys.first)
      end
    end
  end

  def unlink_systems
    if unlink_mode = @join_modes.find { |_id, mode| !mode.linked? }
      join_mode(unlink_mode[0])
    else
      currrent_selected = @join_selected
      if currrent_selected && (current_mode = @join_modes[currrent_selected]?)
        unlink(current_mode.room_ids)
      end
      unlink_internal_use
    end
  rescue error
    logger.warn(exception: error) { "unlink failed" }
  end

  def unlink_internal_use
    @join_lock.synchronize do
      @join_selected = nil unless @join_modes[@join_selected]?.try(&.room_ids.empty?)
      @join_master = true
      self[:join_confirmed] = @join_confirmed = false
      self[:join_master] = true
      self[:joined] = @join_selected
      reset_remote_cache

      persist_join_state
      update_available_ui

      self[:join_confirmed] = @join_confirmed = true
    end

    # only mute on unlink if we're not powering off
    if @mute_on_unlink && status?(Bool, :active)
      @local_outputs.each { |output| unroute(output) }
      @local_preview_outputs.each { |output| unroute(output) }
    end
  rescue error
    logger.error(exception: error) { "ui state failed to be applied unjoining room" }
  end

  protected def persist_join_state
    @ignore_update = Time.utc.to_unix
    define_setting(:join_master, @join_master)
    define_setting(:join_selected, @join_selected)
  rescue error
    logger.error(exception: error) { "failed to persist join state" }
  end

  protected def update_available_ui
    update_available_help
    # VC tab to not be merged
    update_available_tabs
    update_available_outputs
    update_available_mics
    update_available_lighting
    update_available_accessories
  rescue error
    logger.error(exception: error) { "ui state failed to be applied in room join" }
  end

  protected def unlink(rooms : Enumerable(String))
    this_room = config.control_system.not_nil!.id
    rooms.each do |room|
      if room == this_room
        unlink_internal_use
        next
      end
      system(room).get("System", 1).unlink_internal_use
    end
  end

  struct RemoteSystem
    getter system_id : String
    getter room_logic : PlaceOS::Driver::Proxy::Driver

    def initialize(@system_id : String, @room_logic : PlaceOS::Driver::Proxy::Driver)
    end
  end

  protected getter remote_systems : Array(RemoteSystem) do
    if selected = @join_selected
      if mode = @join_modes[selected]
        this_room = config.control_system.not_nil!.id
        if mode.room_ids.includes? this_room
          mode.room_ids.compact_map do |room|
            next if room == this_room
            RemoteSystem.new(room, system(room).get("System", 1))
          end
        else
          [] of RemoteSystem
        end
      else
        [] of RemoteSystem
      end
    else
      [] of RemoteSystem
    end
  end

  # cache the proxies for performance reasons
  protected getter remote_rooms : Array(PlaceOS::Driver::Proxy::Driver) do
    remote_systems.map(&.room_logic)
  end

  protected def reset_remote_cache
    @remote_systems = nil
    @remote_rooms = nil
  end
end
