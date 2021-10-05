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

  @default_routes : Hash(String, String) = {} of String => String

  def on_update
    self[:name] = system.display_name.presence || system.name
    self[:local_help] = @local_help = setting?(Help, :help) || Help.new
    self[:local_tabs] = @local_tabs = setting?(Array(Tab), :tabs) || [] of Tab
    self[:local_outputs] = @local_outputs = setting?(Array(String), :local_outputs) || [] of String
    self[:preview_outputs] = @preview_outputs = setting?(Array(String), :preview_outputs) || [] of String
    @vc_camera_in = setting?(String, :vc_camera_in)

    @default_routes = setting?(Hash(String, String), :default_routes) || {} of String => String

    spawn(same_thread: true) do
      begin
        logger.debug { "loading signal graph..." }
        load_siggraph
        logger.debug { "signal graph loaded" }
        update_available_tabs
        update_available_help
        update_available_outputs
      rescue error
        logger.warn(exception: error) { "error loading signal graph" }
      end
    end

    # manually link screen control to power state
    subscriptions.clear
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

  # Sets the overall room power state.
  def power(state : Bool)
    return if state == self[:active]?
    logger.debug { "Powering #{state ? "up" : "down"}" }
    self[:active] = state

    if state
      system.all(:Camera).power true
      apply_default_routes

      if first_output = @tabs.first?.try &.inputs.first
        selected_input first_output
      end
    else
      system.implementing(Interface::Powerable).power false
    end
  end

  def apply_default_routes
    @default_routes.each { |output, input| route(input, output) }
  rescue error
    logger.warn(exception: error) { "error applying default routes" }
  end

  # Set the volume of a signal node within the system.
  def volume(level : Int32 | Float64, input_or_output : String)
    logger.info { "setting volume on #{input_or_output} to #{level}" }
    level = level.to_f
    node = signal_node input_or_output
    node.proxy.volume level
    self[:volume] = node["volume"] = level
  end

  # Sets the mute state on a signal node within the system.
  def mute(state : Bool = true, input_or_output : Int32 | String = 0, layer : MuteLayer = MuteLayer::AudioVideo)
    # Int32's accepted for Muteable interface compatibility
    unless input_or_output.is_a? String
      raise ArgumentError.new("invalid input or output reference: #{input_or_output}")
    end

    logger.debug { "#{state ? "muting" : "unmuting"} #{input_or_output} #{layer}" }

    node = signal_node input_or_output

    case layer
    in .audio?
      node.proxy.audio_mute(state).get
      node["mute"] = state
    in .video?
      node.proxy.video_mute(state).get
      node["video_mute"] = state
    in .audio_video?
      node.proxy.mute(state).get
      node["mute"] = state
      node["video_mute"] = state
    end

    self[:mute] = state
  end

  def selected_input(name : String) : Nil
    self[:selected_input] = name
    self[:selected_tab] = @tabs.find(@tabs.first, &.inputs.includes?(name)).name

    # Perform any desired routing
    @preview_outputs.each { |output| route(name, output) }
    route(name, @outputs.first) if @outputs.size == 1
  end

  # where name is the camera input selector ()
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
