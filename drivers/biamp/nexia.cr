module Biamp; end

class Biamp::Nexia < PlaceOS::Driver
  # Discovery Information
  tcp_port 23 # Telnet
  descriptive_name "Biamp Nexia/Audia"
  generic_name :Mixer

  alias Ids = Array(UInt32) | UInt32

  def on_load
    # Nexia requires some breathing room
    queue.wait = false
    queue.delay = 30.milliseconds
    transport.tokenizer = Tokenizer.new("\r\n", "\xFF\xFE\x01")
  end

  def on_update
    # min -100
    # max +12

    self["fader_min"] = -36 # specifically for tonsley
    self["fader_max"] = 12
  end

  def connected
    send("\xFF\xFE\x01") # Echo off
    do_send("GETD", 0, "DEVID")

    schedule.every(60.seconds) do
      do_send("GETD", 0, "DEVID")
    end
  end

  def disconnected
    schedule.clear
  end

  def preset(number : UInt32)
    #
    # Recall Device 0 Preset number 1001
    # Device Number will always be 0 for Preset strings
    # 1001 == minimum preset number
    #
    do_send("RECALL", 0, "PRESET", number, name: "preset_#{number}")
  end

  # {1 => [2,3,5], 2 => [2,3,6]}, true
  # Supports Standard, Matrix and Automixers
  def mixer(id : UInt32, inouts : Hash(String, Float32 | Array(Float32)) | Array(Float32), mute : Bool = false, type : String = "matrix")
    value = mute ? 0 : 1

    if inouts.is_a? Hash
      req = type == "matrix" ? "MMMUTEXP" : "SMMUTEXP"

      inouts.each_key do |input|
        outputs = inouts[input]
        outs = ensure_array(outputs)

        outs.each do |output|
          do_send("SET", self["device_id"]?, req, id, input, output, value)
        end
      end
    else # assume array (auto-mixer)
      inouts.each do |input|
        do_send("SET", self["device_id"]?, "AMMUTEXP", id, input, value)
      end
    end
  end

  FADERS = {
    "fader"             => "FDRLVL",
    "matrix_in"         => "MMLVLIN",
    "matrix_out"        => "MMLVLOUT",
    "matrix_crosspoint" => "MMLVLXP",
    "stdmatrix_in"      => "SMLVLIN",
    "stdmatrix_out"     => "SMLVLOUT",
    "auto_in"           => "AMLVLIN",
    "auto_out"          => "AMLVLOUT",
    "io_in"             => "INPLVL",
    "io_out"            => "OUTLVL",
    "FDRLVL"            => "fader",
    "MMLVLIN"           => "matrix_in",
    "MMLVLOUT"          => "matrix_out",
    "MMLVLXP"           => "matrix_crosspoint",
    "SMLVLIN"           => "stdmatrix_in",
    "SMLVLOUT"          => "stdmatrix_out",
    "AMLVLIN"           => "auto_in",
    "AMLVLOUT"          => "auto_out",
    "INPLVL"            => "io_in",
    "OUTLVL"            => "io_out",
  }

  def fader(fader_id : Ids, level : Float32, index : Int32 = 1, type : String = "fader")
    fad_type = FADERS[type]

    # value range: -100 ~ 12
    faders = ensure_array(fader_id)
    faders.each do |fad|
      do_send("SETD", self["device_id"]?, fad_type, fad, index, level, name: "fader_#{fad}")
    end
  end

  def faders(ids : Ids, level : Float32, index : Int32 = 1, type : String = "fader", **args)
    fader(ids, level, index, type)
  end

  MUTES = {
    "fader"         => "FDRMUTE",
    "matrix_in"     => "MMMUTEIN",
    "matrix_out"    => "MMMUTEOUT",
    "auto_in"       => "AMMUTEIN",
    "auto_out"      => "AMMUTEOUT",
    "stdmatrix_in"  => "SMMUTEIN",
    "stdmatrix_out" => "SMOUTMUTE",
    "io_in"         => "INPMUTE",
    "io_out"        => "OUTMUTE",
    "FDRMUTE"       => "fader",
    "MMMUTEIN"      => "matrix_in",
    "MMMUTEOUT"     => "matrix_out",
    "AMMUTEIN"      => "auto_in",
    "AMMUTEOUT"     => "auto_out",
    "SMMUTEIN"      => "stdmatrix_in",
    "SMOUTMUTE"     => "stdmatrix_out",
    "INPMUTE"       => "io_in",
    "OUTMUTE"       => "io_out",
  }

  def mute(fader_id : Ids, val : Bool = true, index : Int32 = 1, type : String = "fader")
    actual = val ? 1 : 0
    mute_type = MUTES[type]

    faders = ensure_array(fader_id)
    faders.each do |fad|
      do_send("SETD", self["device_id"]?, mute_type, fad, index, actual, name: "mute_#{fad}")
    end
  end

  def mutes(ids : Ids, muted : Bool = true, index : Int32 = 1, type : String = "fader", **args)
    mute(ids, muted, index, type)
  end

  def unmute(fader_id : Ids, index : Int32 = 1, type : String = "fader")
    mute(fader_id, false, index, type)
  end

  def query_fader(fader_id : Ids, index : Int32 = 1, type : String = "fader")
    fad = ensure_single(fader_id)
    fad_type = FADERS[type]

    do_send("GETD", self["device_id"]?, fad_type, fad, index)
  end

  def query_faders(ids : Ids, index : Int32 = 1, type : String = "fader", **args)
    query_fader(ids, index, type)
  end

  def query_mute(fader_id : Ids, index : Int32 = 1, type : String = "fader")
    fad = ensure_single(fader_id)
    mute_type = MUTES[type]

    do_send("GETD", self["device_id"]?, mute_type, fad, index)
  end

  def query_mutes(ids : Ids, index : Int32 = 1, type : String = "fader", **args)
    query_mute(ids, index, type)
  end

  def received(data, task)
    data = String.new(data)

    if data =~ /-ERR/
      return task.try &.abort
    else
      logger.debug { "Nexia responded #{data}" }
    end

    # --> "#SETD 0 FDRLVL 29 1 0.000000 +OK"
    data = data.split(" ")
    unless data[2].nil?
      resp_type = data[2]

      if resp_type == "DEVID"
        # "#GETD 0 DEVID 1 "
        self["device_id"] = data[-1].to_i
      elsif MUTES.has_key?(resp_type)
        type = MUTES[resp_type]
        self["#{type}#{data[3]}_#{data[4]}_mute"] = data[5] == "1"
      elsif FADERS.has_key?(resp_type)
        type = FADERS[resp_type]
        self["#{type}#{data[3]}_#{data[4]}"] = data[5]
      end
    end

    task.try &.success
  end

  private def do_send(*args, **options)
    send("#{args.join(' ')} \n", **options)
  end

  private def ensure_array(object)
    object.is_a?(Array) ? object : [object]
  end

  private def ensure_single(object)
    object.is_a?(Array) ? object[0] : object
  end
end
