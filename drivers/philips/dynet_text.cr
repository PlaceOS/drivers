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
    @telnet = Telnet.new { |data| transport.send(data) }
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
      process_response components, task
    elsif data =~ /Connection Established/i
      @ready = true
      self[:ready] = true
    end
  end

  protected def process_response(parts : Hash(String, String), task)
    task_name = task.try(&.name)
    success = task_name.nil?

    check_key = parts.first_key
    case check_key
    when "preset"
    when "channel level channel"
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
        level = parts["currlev"].to_i(strict: false)
        self[area_key] = level
        task.not_nil!.success(level) if task_name == area_key
      end
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

  def trigger(area : Int32, scene : UInt16, fade : Int32 = 1000)

  end

  def get_current_preset(area : UInt16)
    do_send "RequestCurrentPreset #{area}", name: "area#{area}"
  end

  def lighting(area : Int32, state : Bool, fade : Int32 = 1000)

  end

  def light_level(area : Int32, level : Float64, fade : Int32 = 1000, channel : Int32 = 0xFF)

  end

  def get_light_level(area : UInt16, channel : UInt16 = 1_u16)
    do_send "RequestChannelLevel #{channel} #{area}", name: "area#{area}_level"
  end

  def stop_fading(area : Int32, channel : Int32 = 0xFF)

  end
end
