require "placeos-driver"
require "placeos-driver/interface/powerable"

struct Enum
  def to_json(json : JSON::Builder)
    json.string(to_s.underscore)
  end
end

class Place::Rooms::Meet < PlaceOS::Driver
  generic_name :System
  descriptive_name "Meeting room logic"
  description <<-DESC
    Room level state and behaviours.

    This driver provides a high-level API for interaction with devices, systems
    and integrations found within common workplace collaboration spaces. It's
    behavior will adapt to match the capabilities and configuration of other
    drivers present in the same system.
    DESC

  def on_load
    load_mock_state
    on_update
  end

  enum InputType
    Laptop
    Wireless
    PC
  end

  enum OutputType
    LCD
  end

  abstract class Node(Type)
    include JSON::Serializable
    property name : String
    property type : Type
    property mute : Bool? = nil
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
    "table" => Input.new("Table", InputType::Laptop, ["lcd"]),
    "wireless" => Input.new("Vivi", InputType::Wireless, ["lcd"]),
    "opc" => Input.new("PC", InputType::PC, ["lcd"])
  }

  @outputs = {
    "lcd" => Output.new("LCD", OutputType::LCD, "Display_1", ["table", "wireless", "opc"])
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
    # Nothing to do...
  end

  def shutdown
    logger.debug { "Shutting down" }
    system.implementing(PlaceOS::Driver::Interface::Powerable).power false
  end

  def route(input : String, output : String)
    logger.debug { "Routing #{input} -> #{output}" }
    src = @inputs[input].n_id
    dst = @outputs[output].n_id
    lcd = system["Display_1"]
    lcd.power true
    case input
    when "table"
      lcd.switch_to "Hdmi"
    when "wireless"
      lcd.switch_to "Hdmi2"
    when "opc"
      lcd.switch_to "Option"
    end
    update_o(output) { |o| o.source = input }
  end

  def mute(input_or_output : String, state : Bool = true)
    logger.debug { "#{state ? "Muting" : "Unmuting"} #{input_or_output}" }
    case input_or_output
    when "lcd"
      system["Display_1"].mute_audio state
      update_o("lcd") { |o| o.mute = state }
    end
  end

  def unmute(input_or_output : String)
    mute input_or_output, false
  end
end
