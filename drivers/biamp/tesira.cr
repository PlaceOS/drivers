require "telnet"

module Biamp; end

class Biamp::Tesira < PlaceOS::Driver
  # Discovery Information
  tcp_port 23 # Telnet
  descriptive_name "Biamp Tesira"
  generic_name :Mixer

  default_settings({
    no_password: true,
    username:    "default",
    password:    "default",
  })

  alias Num = Int32 | Float64
  alias Ids = String | Array(String)

  def on_load
    # Nexia requires some breathing room
    queue.wait = false
    queue.delay = 30.milliseconds
  end

  def connected
    @telnet = telnet = Telnet.new do |telnet_response|
      transport.send telnet_response
    end
    transport.pre_processor { |bytes| telnet.buffer(bytes) }

    if setting(Bool, :no_password)
      do_send setting(String, :username) || "admin", wait: false, delay: 200.milliseconds, priority: 98
      do_send setting(String, :password), wait: false, delay: 200.milliseconds, priority: 97
    end
    do_send "SESSION set verbose false", priority: 96

    schedule.every(60.seconds) do
      do_send "DEVICE get serialNumber", priority: 0
    end
  end

  def disconnected
    transport.tokenizer = nil
    schedule.clear
  end

  def preset(number_or_name : String | Int32)
    if number_or_name.is_a? Int32
      do_send "DEVICE recallPreset #{number_or_name}"
    else
      do_send build(:DEVICE, :recallPresetByName, number_or_name)
    end
  end

  def start_audio
    do_send "DEVICE startAudio"
  end

  def reboot
    do_send "DEVICE reboot"
  end

  def get_aliases
    do_send "SESSION get aliases"
  end

  MIXERS = {
    "matrix" => "crosspointLevelState",
    "mixer"  => "crosspoint",
  }

  def mixer(id : String, inouts : Hash(Int32, Int32 | Array(Int32)) | Array(Int32), mute : Bool = false, type : String = "matrix")
    mixer_type = MIXERS[type] || type

    if inouts.is_a? Hash
      inouts.each do |input, outs|
        outputs = ensure_array(outs)
        outputs.each do |output|
          do_send build(id, :set, mixer_type, input, output, mute)
        end
      end
    else # assume array (auto-mixer)
      inouts.each do |input|
        do_send_now build(id, :set, mixer_type, input, mute)
      end
    end
  end

  FADERS = {
    "fader"             => "level",
    "matrix_in"         => "inputLevel",
    "matrix_out"        => "outputLevel",
    "matrix_crosspoint" => "crosspointLevel",
    "level"             => "fader",
    "inputLevel"        => "matrix_in",
    "outputLevel"       => "matrix_out",
    "crosspointLevel"   => "matrix_crosspoint",
  }

  def fader(fader_id : Ids, level : Num | Bool, index : Int32 | Array(Int32) = 1, type : String = "fader")
    # value range: -100 ~ 12
    fader_type = FADERS[type] || type

    fader_ids = ensure_array(fader_id)
    indicies = ensure_array(index)
    fader_ids.each do |fad|
      indicies.each do |i|
        do_send_now build(fad, :set, fader_type, i, level)
        self["#{fader_type}_#{fad}_#{i}"] = level
      end
    end
  end

  # Named params version
  def faders(ids : Ids, level : Num | Bool, index : Int32 | Array(Int32) = 1, type : String = "fader")
    fader(ids, level, index, type)
  end

  MUTES = {
    "fader"      => "mute",
    "matrix_in"  => "inputMute",
    "matrix_out" => "outputMute",
    "mute"       => "fader",
    "inputMute"  => "matrix_in",
    "outputMute" => "matrix_out",
  }

  def mute(fader_id : Ids, value : Bool = true, index : Int32 | Array(Int32) = 1, type : String = "fader")
    mute_type = MUTES[type] || type

    fader_ids = ensure_array(fader_id)
    indicies = ensure_array(index)
    fader_ids.each do |fad|
      indicies.each do |i|
        do_send_now build(fad, :set, mute_type, i, value)
        self["#{mute_type}_#{fad}_#{i}_mute"] = value
      end
    end
  end

  # Named params version
  def mutes(ids : Ids, muted : Bool, index : Int32 | Array(Int32) = 1, type : String = "fader")
    mute(ids, muted, index, type)
  end

  def unmute(fader_id : Ids, index : Int32 | Array(Int32) = 1, type : String = "fader")
    mute(fader_id, false, index, type)
  end

  def query_fader(fader_id : Ids, index : Int32 | Array(Int32) = 1, type : String = "fader")
    fad_type = FADERS[type] || type
    fader_id = ensure_array(fader_id)[0]
    index = ensure_array(index)[0]

    do_send build(fader_id, :get, fad_type, index)
  end

  # Named params version
  def query_faders(ids : Ids, index : Int32 | Array(Int32) = 1, type : String = "fader")
    query_fader(ids, index, type)
  end

  def query_mute(fader_id : Ids, index : Int32 | Array(Int32) = 1, type : String = "fader")
    mute_type = MUTES[type] || type
    fader_id = ensure_array(fader_id)[0]
    index = ensure_array(index)[0]

    do_send build(fader_id, :get, mute_type, index)
  end

  # Named params version
  def query_mutes(ids : Ids, index : Int32 | Array(Int32) = 1, type : String = "fader")
    query_mute(ids, index, type)
  end

  def received(data, task)
    data = String.new(data).strip

    logger.debug { "Tesira responded -> data: #{data}" }
    result = data.split(" ")

    if result[0] == "-"
      task.try(&.abort)
    end

    if data =~ /login:|server/i
      transport.tokenizer = Tokenizer.new "\r\n"
    end

    task.try(&.success)
  end

  private def build(*args)
    cmd = ""
    args.each do |arg|
      data = arg.to_s
      next if data.blank?
      cmd = cmd + " " if cmd.size > 0

      if data.includes? " "
        cmd = cmd + "\""
        cmd = cmd + data
        cmd = cmd + "\""
      else
        cmd = cmd + data
      end
    end
    cmd
  end

  private def do_send(command, **options)
    logger.debug { "requesting #{command}" }
    send @telnet.not_nil!.prepare(command), **options
  end

  private def do_send_now(command)
    logger.debug { "requesting #{command}" }
    transport.send @telnet.not_nil!.prepare(command)
  end

  private def ensure_array(object)
    object.is_a?(Array) ? object : [object]
  end
end
