require "placeos-driver"
require "telnet"

# Documentation: https://aca.im/driver_docs/Philips/DYN_CG_INT_EnvisionGateway_R05.pdf
# See page 58

class Philips::DyNetText < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Philips DyNet Text Protocol"
  generic_name :Lighting
  tcp_port 23

  @ready : Bool = false

  protected getter! telnet : Telnet

  def on_load
    new_telnet_client
    transport.pre_processor { |bytes| telnet.buffer(bytes) }
    transport.tokenizer = Tokenizer.new("\r\n")
  end

  def connected
    @ready = false
    self[:ready] = false

    schedule.every(60.seconds) do
      logger.debug { "-- polling gateway" }
      get_date
    end
  end

  def disconnected
    # Ensures the buffer is cleared
    new_telnet_client
    schedule.clear
  end

  protected def new_telnet_client
    @telnet = Telnet.new { |data| puts "neg: #{data.hexstring}"; transport.send(data) }
  end

  def received(data, task)
    data = String.new(data).strip
    return if data.empty?

    logger.debug { "Dynalite sent: #{data}" }

    if @ready
      # Extract response
      components = data.split(", ").map { |component|
        parts = component.downcase.split
        value = parts.pop
        key = parts.join(' ')
        {key, value}
      }.to_h
      process_response data, components, task
    elsif data =~ /Connection Established/i
      @ready = true
      self[:ready] = true

      # Turn off echo
      do_send "Echo 0", name: "echo"
      # ensure verbose messages
      do_send "Verbose", name: "verbose"
      # Reply with OK
      do_send "ReplyOK 1", name: "replies"
      # default join is FF
      do_send "Join 255", name: "join"
    end
  end

  # ameba:disable Metrics/CyclomaticComplexity
  protected def process_response(message : String, parts : Hash(String, String), task)
    task_name = task.try(&.name)
    success = task_name.nil?

    # For execute commands we consider complete once we get the OK message
    if message == "OK"
      return unless task_name
      case task_name
      when .starts_with?("preset"), .starts_with?("level"), .starts_with?("stopfade"), "echo", "verbose", "replies", "join"
        logger.debug { "execute #{task_name} success!" }
        task.try(&.success)
      end
      return
    end

    check_key = parts.first_key
    case check_key
    when "preset"
      area = parts["area"]?
      # return here if we are just getting the echo of our request
      return unless area
      area = area.to_i
      self["area#{area}"] = parts.first_value.to_i
    when "channel level channel"
      area = parts["area"].to_i
      self["area#{area}_level"] = parts["level"].to_i(strict: false)
    when .starts_with?("date")
      success = true if task_name == "date"
    when .starts_with?("time")
      success = true if task_name == "time"
    when .starts_with?("reply")
      case check_key
      when .ends_with?("current preset")
        preset = parts.first_value.to_i
        area = parts["area"].to_i
        area_key = "area#{area}"
        self[area_key] = preset
        task.not_nil!.success(preset) if task_name == area_key
      when .ends_with?("level ch")
        area = parts["area"].to_i
        area_key = "area#{area}_level"
        level = parts["targlev"].to_i(strict: false)
        self[area_key] = level
        task.not_nil!.success(level) if task_name == area_key
      end
    when "channellevel", "stopfade"
      # we ignore this echo
    else
      logger.debug { "ignorning message: #{message}" }
    end

    # ignore unless sucess
    task.try(&.success) if success
  end

  protected def do_send(command, **options)
    send telnet.prepare(command), **options
  end

  def get_date
    do_send "RequestDate", name: :date
  end

  def get_time
    do_send "RequestTime", name: :time
  end

  def trigger(area : UInt16, scene : UInt16, fade : UInt16 = 1000_u16)
    do_send "Preset #{scene} #{area} #{fade}", name: "preset#{area}"
  end

  def get_current_preset(area : UInt16)
    do_send "RequestCurrentPreset #{area}", name: "area#{area}"
  end

  def lighting(area : UInt16, state : Bool, fade : UInt16 = 1000_u16)
    light_level(area, state ? 100.0 : 0.0, fade)
  end

  def light_level(area : UInt16, level : Float64, fade : UInt16 = 1000_u16, channel : UInt8 = 0_u8)
    # channel 0 is all channels
    level = level.round_away.to_i
    do_send "ChannelLevel #{channel} #{level.clamp(0, 100)} #{area} #{fade}", name: "level#{area}_#{channel}"
  end

  def get_light_level(area : UInt16, channel : UInt8 = 1_u8)
    # can't request level of channel 0 (all channels) so we default to channel 1 which should always exist
    do_send "RequestChannelLevel #{channel} #{area}", name: "area#{area}_level"
  end

  def stop_fading(area : UInt16, channel : UInt8 = 0_u8)
    do_send "StopFade #{channel} #{area}", name: "stopfade#{area}_#{channel}"
  end
end
