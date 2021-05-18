require "placeos-driver/interface/muteable"
# require "placeos-driver/interface/switchable"

# Documentation: https://aca.im/driver_docs/AMX/N8000SeriesAPICommandListRev1.1.pdf

class Amx::Svsi::NSeriesEncoder < PlaceOS::Driver
  include Interface::Muteable

  enum Input
    Hdmionly
    Vgaonly
    Hdmivga
    Vgahdmi
  end

  # include Interface::InputSelection(Input)

  tcp_port 50002
  descriptive_name "AMX SVSI N-Series Switcher"
  generic_name :Switcher

  alias InOut = String | Int32

  @volume_min = 0
  @volume_max = 100
  @inputs : Hash(String, String) = {} of String => String
  @outputs : Hash(String, String) = {} of String => String
  @encoders = [] of String
  @decoders = [] of String
  @lookup : Hash(String, String) = {} of String => String
  @list = [] of String

  def on_load
    transport.tokenizer = Tokenizer.new("</status>")
    on_update
  end

  def on_update
    @inputs = setting?(Hash(String, String), :inputs) || {} of String => String
    @outputs = setting?(Hash(String, String), :outputs) || {} of String => String

    @encoders = @inputs.keys
    @decoders = @outputs.keys

    @lookup = @inputs.merge(@outputs)
    @list = @encoders + @decoders
  end

  def connected
    @lookup.each_key do |ip_address|
      monitor(ip_address, priority: 0)
      monitornotify(ip_address, priority: 0)
    end

    schedule.every(50.seconds) {
      logger.debug { "-- Maintaining Connection --" }
      monitornotify(@list.first, priority: 0)
    }
  end

  def disconnected
    schedule.clear
  end

  CommonCommands = [
    :monitor, :monitornotify,
    :live, :local, :serial, :readresponse, :sendir, :sendirraw, :audioon, :audiooff,
    :enablehdmiaudio, :disablehdmiaudio, :autohdmiaudio,
    # recorder commands
    :record, :dsrecord, :dvrswitch1, :dvrswitch2, :mpeg, :mpegall, :deletempegfile,
    :play, :stop, :pause, :unpause, :fastforward, :rewind, :deletefile, :stepforward,
    :stepreverse, :stoprecord, :recordhold, :recordrelease, :playhold, :playrelease,
    :deleteallplaylist, :deleteallmpegs, :remotecopy,
    # window processor commands
    :wpswitch, :wpaudioin, :wpactive, :wpinactive, :wpaudioon, :wpaudiooff, :wpmodeon,
    :wpmodeoff, :wparrange, :wpbackground, :wpcrop, :wppriority, :wpbordon, :wpbordoff,
    :wppreset,
    # audio transceiver commands
    :atrswitch, :atrmute, :atrunmute, :atrtxmute, :atrtxunmute, :atrhpvol, :atrlovol,
    :atrlovolup, :atrlovoldown, :atrhpvolup, :atrhpvoldown, :openrelay, :closerelay,
    # video wall commands
    :videowall,
    # miscellaneous commands
    :script, :goto, :tcpclient, :udpclient, :reboot, :gc_serial, :gc_openrelay,
    :gc_closerelay, :gc_ir
  ]

  {% for name in CommonCommands %}
    def {{name.id}}(ip_address : String, *args, **options)
      do_send({{name.id.stringify}}, ip_address, *args, **options)
    end
  {% end %}

  def serialhex(ip_address : String, wait_time : Int32 = 1, *data, **options)
    do_send("serialhex", wait_time, ip_address, *data, **options)
  end

  # Encoder Commands
  {% for name in [:modeoff, :enablecc, :disablecc, :autocc, :uncompressedoff] %}
    def {{name.id}}(input : InOut, *args, **options)
      do_send({{name.id.stringify}}, get_input(input), *args, **options)
    end
  {% end %}

  # Decoder Commands
  {% for name in [:audiofollow, :volume, :dvion, :dvioff, :cropref, :getStatus] %}
    def {{name.id}}(output : InOut, *args, **options)
      do_send({{name.id.stringify}}, get_output(output), *args, **options)
    end
  {% end %}

  def switch(inouts : Hash(Int32, InOut | Array(InOut)), **options)
    inouts.each do |input, output|
      outputs = output.is_a?(InOut) ? [output] : output
      if input != 0
        # 'in_ip' => ['ip1', 'ip2'] etc
        input_actual = get_input(input)
        outputs.each do |o|
          output_actual = get_output(o)

          dvion(output_actual, **options)
          audioon(output_actual, **options)
          audiofollow(output_actual, **options)

          self["video#{output_actual}"] = input_actual
          self["audio#{output_actual}"] = input_actual
          do_send(:switch, output_actual, input_actual, **options)
        end
      else
        # nil => ['ip1', 'ip2'] etc
        outputs.each do |o|
          output_actual = get_output(o)
          dvioff(output_actual, **options)
          audiooff(output_actual, **options)
        end
      end
    end
  end

  def switch_audio(inouts : Hash(Int32, InOut | Array(InOut)), **options)
    inouts.each do |input, output|
      outputs = output.is_a?(InOut) ? [output] : output
        if input != 0
          # 'in_ip' => ['ip1', 'ip2'] etc
          input_actual = get_input(input)
          outputs.each do |o|
            output_actual = get_output(o)

            audioon(input_actual,  **options)
            audioon(output_actual, **options)

            self["audio#{output_actual}"] = input_actual
            do_send(:switchaudio, output_actual, input_actual, **options)
          end
        else
          # nil => ['ip1', 'ip2'] etc
          outputs.each do |o|
            audiooff(get_output(o), **options)
          end
        end
    end
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    address = index.is_a?(Int32) && (val = @encoders[index]? || @decoders[index]?) ? val : index.as(String)
    if state
      dvioff(address) if layer.audio_video? || layer.video?
      audiooff(address) if layer.audio_video? || layer.audio?
    else
      dvion(address) if layer.audio_video? || layer.video?
      audioon(address) if layer.audio_video? || layer.audio?
    end
  end

  def received(data, task)
    data = String.new(data)
    logger.debug { "Received: #{data}" }

    resp = data.split(':')

    case resp.size
    when 13 # Encoder or decoder status
      self[resp[0]] = {
        communications: resp[1] == "1",
        dvioff: resp[2] == "1",
        scaler: resp[3] == "1",
        source_detected: resp[4] == "1",
        mode: resp[5],
        audio_enabled: resp[6] == "1",
        video_stream: resp[7].to_i,
        audio_stream: resp[8] == "follow video" ? resp[8] : resp[8].to_i,
        playlist: resp[9],
        colorspace: resp[10],
        hdmiaudio: resp[11],
        resolution: resp[12]
      }
    when 10 # Audio Transceiver or window processor status
      self[resp[0]] = resp
    else
      logger.warn { "unknown response type: #{resp}" }
    end

    task.try(&.success)
  end

  def do_send(*args, **options)
    cmd = args.join(' ')
    logger.debug { "sending #{cmd}" }
    send("#{cmd}\r\n", **options)
  end

  private def get_input(address : InOut) : String
    if address.is_a?(String) && @inputs[address]?
      address
    elsif address.is_a?(Int32) && (input = @encoders[address]?)
      input
    else
      logger.warn { "unknown address #{address}" }
      address.to_s
    end
  end

  private def get_output(address : InOut) : String
    if address.is_a?(String) && @outputs[address]?
      address
    elsif address.is_a?(Int32) && (output = @decoders[address]?)
      output
    else
      logger.warn { "unknown address #{address}" }
      address.to_s
    end
  end
end
