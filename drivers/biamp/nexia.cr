require "placeos-driver"
require "inactive-support/mapped_enum"
require "./ntp"

class Biamp::Nexia < PlaceOS::Driver
  include Biamp::NTP

  tcp_port 23
  descriptive_name "Biamp Nexia/Audia"
  generic_name :Mixer

  protected property device_id = 0

  def on_load
    queue.delay = 30.milliseconds
    transport.tokenizer = Tokenizer.new("\r\n", "\xFF\xFE\x01")
  end

  def connected
    send Bytes[0xFF, 0xFE, 0x01], wait: false # Echo off
    schedule.every(60.seconds, true) do
      query_device_id
    end
  end

  def disconnected
    schedule.clear
  end

  def query_device_id
    send Command[:GETD, 0, "DEVID"]
  end

  def preset(number : Int32)
    send Command[:RECALL, 0, "PRESET", number], name: "preset_#{number}"
  end

  mapped_enum Mixer do
    Matrix   = "MMMUTEXP"
    Standard = "SMMUTEXP"
    Auto     = "AMMUTEXP"
  end

  def mixer(id : Int32, inouts : Hash(Int32, Array(Int32)) | Array(Int32), mute : Bool = false, type : Mixer = Mixer::Matrix)
    value = mute ? 0 : 1

    if inouts.is_a? Hash
      inouts.each do |input, outputs|
        outputs.each do |output|
          send Command[:SET, device_id, type.mapped_value, id, input, output, value]
        end
      end
    else
      inouts.each do |input|
        send Command[:SET, device_id, Mixer::Auto.mapped_value, id, input, value]
      end
    end
  end

  mapped_enum Faders do
    Fader            = "FDRLVL"
    MatrixIn         = "MMLVLIN"
    MatrixOut        = "MMLVLOUT"
    MatrixCrosspoint = "MMLVLXP"
    StdmatrixIn      = "SMLVLIN"
    StdmatrixOut     = "SMLVLOUT"
    AutoIn           = "AMLVLIN"
    AutoOut          = "AMLVLOUT"
    IoIn             = "INPLVL"
    IoOut            = "OUTLVL"
  end

  def fader(id : Int32, level : Float32, index : Int32 = 1, type : Faders = Faders::Fader)
    send Command[:SETD, device_id, type.mapped_value, id, index, level], name: "fader_#{id}"
  end

  def query_fader(id : Int32, index : Int32 = 1, type : Faders = Faders::Fader)
    send Command[:GETD, device_id, type.mapped_value, id, index]
  end

  mapped_enum Mutes do
    Fader        = "FDRMUTE"
    MatrixIn     = "MMMUTEIN"
    MatrixOut    = "MMMUTEOUT"
    AutoIn       = "AMMUTEIN"
    AutoOut      = "AMMUTEOUT"
    StdmatrixIn  = "SMMUTEIN"
    StdmatrixOut = "SMOUTMUTE"
    IoIn         = "INPMUTE"
    IoOut        = "OUTMUTE"
  end

  def mute(id : Int32, state : Bool = true, index : Int32 = 1, type : Mutes = Mutes::Fader)
    value = state ? 1 : 0
    send Command[:SETD, device_id, type.mapped_value, id, index, value], name: "mute_#{id}"
  end

  def unmute(id : Int32, index : Int32 = 1, type : Mutes = Mutes::Fader)
    mute(id, false, index, type)
  end

  def query_mute(id : Int32, index : Int32 = 1, type : Mutes = Mutes::Fader)
    send Command[:GETD, device_id, type.mapped_value, id, index]
  end

  def received(data, task)
    case response = Response.parse data
    in Response::FullPath
      logger.debug { "Device responded #{response.message}" }
      result = process_full_path_response response
      task.try &.success result
    in Response::OK
      logger.info { "OK" }
      task.try &.success
    in Response::Error
      logger.warn { "Device error: #{data}" }
      task.try &.abort(response.message)
    in Response::Invalid
      logger.error { "Invalid response structure" }
      task.try &.abort(response.data)
    end
  end

  protected def process_full_path_response(response)
    case response.attribute
    when "DEVID"
      self["device_id"] = self.device_id = response.value.to_i
    else
      if mute = Mutes.from_mapped_value? response.attribute
        id, index = response.params
        self["#{mute.to_s.underscore}#{id}_#{index}_mute"] = response.value == "1"
      elsif fader = Faders.from_mapped_value? response.attribute
        id, index = response.params
        self["#{fader.to_s.underscore}#{id}_#{index}"] = response.value.to_f
      end
    end
  end
end
