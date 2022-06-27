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
    data = String.new(data).strip("\x00\r\n\t ")
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
      if task && task_name
        # We want to process replies completely (return the value)
        # however we don't want to retry in case the target doesn't exist
        if task_name.starts_with?("get_")
          task.retries = 0
        else
          logger.debug { "execute #{task_name} success!" }
          task.success
        end
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
        join = get_join parts["join"]
        area_key = join == 255 ? "area#{area}" : "area#{area}-#{join}"
        self[area_key] = preset
        task.not_nil!.success(preset) if task_name == "get_#{area_key}"
      when .ends_with?("level ch")
        area = parts["area"].to_i
        join = get_join parts["join"]
        area_key = join == 255 ? "area#{area}_level" : "area#{area}-#{join}_level"
        level = parts["targlev"].to_i(strict: false)
        self[area_key] = level
        task.not_nil!.success(level) if task_name == "get_#{area_key}"
      end
    when "channellevel", "stopfade", .starts_with?("requestcurrentpreset"), .starts_with?("requestchannellevel")
      # we ignore this echo
    else
      logger.debug { "ignorning message: #{message}, key: #{check_key.inspect}" }
    end

    # ignore unless sucess
    task.try(&.success) if success
  end

  protected def do_send(command, **options)
    send telnet.prepare(command), **options
  end

  protected def get_join(value : String)
    value = value.rchop("hex")
    value = value.lchop("0x")
    value.to_i(16)
  end

  def get_date
    do_send "RequestDate", name: :date
  end

  def get_time
    do_send "RequestTime", name: :time
  end

  def trigger(area : UInt16, scene : UInt16, join : UInt8 = 0xFF_u8, fade : UInt32 = 1000_u32)
    do_send "Preset #{scene} #{area} #{fade} #{join}", name: "preset#{area}_#{join}"
  end

  def get_current_preset(area : UInt16, join : UInt8 = 0xFF_u8)
    do_send "RequestCurrentPreset #{area} #{join}", name: (join == 255_u8 ? "get_area#{area}" : "get_area#{area}-#{join}")
  end

  def lighting(area : UInt16, state : Bool, join : UInt8 = 0xFF_u8, fade : UInt32 = 1000_u32)
    light_level(area, state ? 100.0 : 0.0, join, fade)
  end

  def light_level(area : UInt16, level : Float64, join : UInt8 = 0xFF_u8, fade : UInt32 = 1000_u32, channel : UInt16 = 0_u16)
    # channel 0 is all channels
    level = level.round_away.to_i
    do_send "ChannelLevel #{channel} #{level.clamp(0, 100)} #{area} #{fade} #{join}", name: "level#{area}_#{channel}_#{join}"
  end

  def get_light_level(area : UInt16, join : UInt8 = 0xFF_u8, channel : UInt16 = 1_u16)
    # can't request level of channel 0 (all channels) so we default to channel 1 which should always exist
    do_send "RequestChannelLevel #{channel} #{area} #{join}", name: (join == 255_u8 ? "get_area#{area}_level" : "get_area#{area}-#{join}_level")
  end

  def stop_fading(area : UInt16, join : UInt8 = 0xFF_u8, channel : UInt16 = 0_u16)
    do_send "StopFade #{channel} #{area} #{join}", name: "stopfade#{area}_#{join}_#{channel}"
  end
end
