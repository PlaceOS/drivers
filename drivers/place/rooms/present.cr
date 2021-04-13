require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/switchable"

struct Enum
  def to_json(json : JSON::Builder)
    json.string(to_s.underscore)
  end
end

class Place::Rooms::Present < PlaceOS::Driver
  generic_name :System
  descriptive_name "Presentation space logic"
  description <<-DESC
    Room level state and behaviours.

    This driver provides a high-level API for interaction with devices, systems
    and integrations found within common presentation spaces. It's behavior will
    adapt to match the capabilities and configuration of other drivers present
    in the same system.
    DESC

  accessor proj : Projector_1, implementing: InputSelection
  accessor prev : Display_1, implementing: InputSelection
  accessor lcd1 : Display_2, implementing: InputSelection
  accessor lcd2 : Display_3, implementing: InputSelection
  accessor lcd3 : Display_4, implementing: InputSelection
  accessor switcher : Switcher_1, implementing: Switchable

  def on_load
    load_mock_state
    on_update
  end

  enum InputType
    Laptop
    Wireless
    PC
    DocCam
  end

  enum OutputType
    LCD
    Projector
  end

  abstract class Node(Type)
    include JSON::Serializable
    property name : String
    property type : Type
    property mute : Bool? = nil
    property volume : Int32? = nil
    property n_id : UInt64 = rand(UInt64)
  end

  class Input < Node(InputType)
    property outputs = [] of String
    def initialize(@name, @type, @outputs); end
  end

  class Output < Node(OutputType)
    property mod : String
    property source : String? = nil
    property inputs = [] of String
    def initialize(@name, @type, @mod, @inputs); end
  end

  @inputs = {
    "vga" => Input.new("VGA", InputType::Laptop, ["proj", "prev"]),
    "hdmi" => Input.new("HDMI", InputType::Laptop, ["proj", "prev"]),
    "pc" => Input.new("PC", InputType::PC, ["proj", "prev"]),
    "doccam" => Input.new("Visualiser", InputType::DocCam, ["proj", "prev"]),
    "opc1" => Input.new("PC", InputType::PC, ["lcd1"]),
    "opc2" => Input.new("PC", InputType::PC, ["lcd2"]),
    "opc3" => Input.new("PC", InputType::PC, ["lcd3"])
  }

  @outputs = {
    "proj" => Output.new("Projector", OutputType::LCD, "Projector_1", ["vga", "hdmi", "doccam"]),
    "prev" => Output.new("LCD", OutputType::LCD, "Display_1", ["vga", "hdmi", "doccam"]),
    "lcd1" => Output.new("LCD", OutputType::LCD, "Display_2", ["opc1"]),
    "lcd2" => Output.new("LCD", OutputType::LCD, "Display_3", ["opc2"]),
    "lcd3" => Output.new("LCD", OutputType::LCD, "Display_4", ["opc3"])
  }

  private def update_o(name : String)
    yield @outputs[name]
    self["output/#{name}"] = @outputs[name]
  end

  private def load_mock_state
    self[:inputs] = @inputs.map { |key, meta| self["input/#{key}"] = meta; key }
    self[:outputs] = @outputs.map { |key, meta| self["output/#{key}"] = meta; key }
  end

  def on_update
    self[:name] = system.name
  end

  def powerup
    logger.debug { "Powering up" }
    self[:active] = true
  end

  def shutdown
    logger.debug { "Shutting down" }
    system.implementing(PlaceOS::Driver::Interface::Powerable).power false
    self[:active] = false
  end

  def route(input : String, output : String)
    logger.debug { "Routing #{input} -> #{output}" }
    raise "Cannot route #{input} to #{output}" unless input.in? @outputs[output].inputs
    case input
    when "vga"
      switcher.switch_to 1
    when "pc"
      switcher.switch_to 3
    when "hdmi"
      switcher.switch_to 4
    when "doccam"
      switcher.switch_to 5
    when "opc1"
      lcd1.switch_to "Option"
    when "opc2"
      lcd2.switch_to "Option"
    when "opc3"
      lcd3.switch_to "Option"
    end
    update_o(output) { |o| o.source = input }
  end

  def mute(state : Bool = true, input_or_output : String = "proj")
    logger.debug { "#{state ? "Muting" : "Unmuting"} #{input_or_output}" }
    case input_or_output
    when "proj"
      switcher.mute state
      update_o("proj") { |o| o.mute = state }
      self[:mute] = state
    end
  end

  def unmute(input_or_output : String = "proj")
    mute false, input_or_output
  end

  def volume(level : Int32, input_or_output : String = "proj")
    level = level.clamp 0, 100
    logger.debug { "Setting volume #{level} on #{input_or_output}" }
    case input_or_output
    when "proj"
      switcher.volume level
      update_o("proj") { |o| o.volume = level }
      self[:volume] = level
    end
  end
end
