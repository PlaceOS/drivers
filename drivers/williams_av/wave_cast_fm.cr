require "placeos-driver"

# Documentation: https://aca.im/driver_docs/WilliamsAV/WaveCAST-MAN-262D-WCFM.pdf

class WilliamsAV::WaveCastFM < PlaceOS::Driver
  # Discovery Information:
  generic_name :HearingAugmentation
  descriptive_name "WilliamsAV WaveCast / FM"
  uri_base "http://192.168.0.1"

  default_settings({
    # only a single connection can be maintained at a time
    http_max_requests: 0,
    # supports 0-7
    channel_number: 0,
  })

  def on_load
    on_update
  end

  def on_update
    @channel_number = setting?(Int32, :channel_number)
    schedule.clear

    # ensure query run at the same time for offset to work
    schedule.cron("* * * * *") { connected }
  end

  def channel_offset
    (3000 * (@channel_number || 0)) + rand(750)
  end

  def connected
    schedule.in(channel_offset.milliseconds) { query_state }
  end

  getter channel_number : Int32? = nil

  enum Command
    TDU8_REBOOT
    TDU8_RESTORE_DEFAULTS
    TDU8_VU_METER_VALUE
    TDU8_INPUT_GAIN
    TDU8_INPUT_SOURCE
    TDU8_PRESET
    TDU8_HIGH_PASS
    TDU8_LOW_PASS
    TDU8_COMPRESSION
    TDU8_USE_DHCP
    TDU8_AUDIO_TX_MODE
    TDU8_TTL
    TDU8_SECURE_MODE
    TDU8_PANEL_LOCK
    TDU32_RF_TIMEOUT
    TDU8_RF_CHANNEL
    TDU8_RF_17_CHANNEL_MODE
    TDU8_RF_POWER
    TDSTR_SERVER_NAME
    TDSTR_STATIC_IP_ADDR
    TDSTR_STATIC_SUBNET_MASK
    TDSTR_STATIC_GATEWAY_ADDR
    TDSTR_MULTICAST_ADDR
    TDSTR_JOIN_CODE
  end

  enum Type
    TT_FLOAT # float
    TT_U8    # uint8
    TT_U32   # uint32
    TT_S8    # int8
    TT_S32   # int32
    TT_STRING
  end

  TYPES = {
    Command::TDU8_REBOOT               => Type::TT_U8,
    Command::TDU8_RESTORE_DEFAULTS     => Type::TT_U8,
    Command::TDU8_VU_METER_VALUE       => Type::TT_U8,
    Command::TDU8_INPUT_GAIN           => Type::TT_U8,
    Command::TDU8_INPUT_SOURCE         => Type::TT_U8,
    Command::TDU8_PRESET               => Type::TT_U8,
    Command::TDU8_HIGH_PASS            => Type::TT_U8,
    Command::TDU8_LOW_PASS             => Type::TT_U8,
    Command::TDU8_COMPRESSION          => Type::TT_U8,
    Command::TDU8_USE_DHCP             => Type::TT_U8,
    Command::TDU8_AUDIO_TX_MODE        => Type::TT_U8,
    Command::TDU8_TTL                  => Type::TT_U8,
    Command::TDU8_SECURE_MODE          => Type::TT_U8,
    Command::TDU8_PANEL_LOCK           => Type::TT_U8,
    Command::TDU32_RF_TIMEOUT          => Type::TT_U32,
    Command::TDU8_RF_CHANNEL           => Type::TT_U8,
    Command::TDU8_RF_17_CHANNEL_MODE   => Type::TT_U8,
    Command::TDU8_RF_POWER             => Type::TT_U8,
    Command::TDSTR_SERVER_NAME         => Type::TT_STRING,
    Command::TDSTR_STATIC_IP_ADDR      => Type::TT_STRING,
    Command::TDSTR_STATIC_SUBNET_MASK  => Type::TT_STRING,
    Command::TDSTR_STATIC_GATEWAY_ADDR => Type::TT_STRING,
    Command::TDSTR_MULTICAST_ADDR      => Type::TT_STRING,
    Command::TDSTR_JOIN_CODE           => Type::TT_STRING,
  }

  def query_state
    if channel = channel_number
      body_data = URI::Params.build { |form|
        form.add "type", "TT_U8"
        form.add "id", "TDU8_CURRENT_CHANNEL"
        form.add "value", channel.to_s
      }.to_s

      logger.debug { "switching current channel to: #{channel}" }

      response = post("/TBL-WRITE", body: body_data)
      raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?
    end

    response = get("/TBL-READ?All")
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    count = 0
    response.body.split('\n').each do |line|
      next unless line.presence
      parts = line.split(",").map!(&.strip)
      begin
        type = Type.parse(parts[0])
        command = Command.parse?(parts[1]) || parts[1]
        value_raw = parts[2]

        value = case type
                in Type::TT_FLOAT
                  value_raw.to_f
                in Type::TT_U8, Type::TT_U32, Type::TT_S8, Type::TT_S32
                  value_raw.to_i
                in Type::TT_STRING
                  value_raw
                end

        set_status(command, value)
        count += 1
      rescue error
        raise "error parsing response line\n#{error.inspect_with_backtrace}"
      end
    end
    "#{count} values updated"
  end

  protected def set_status(command : Command | String, value)
    command_str = command.to_s.split('_', 2)[1].downcase

    case command
    when Command::TDU8_SECURE_MODE
      command_str = "join_code_enabled"
      value = value == 1
    when Command::TDU8_AUDIO_TX_MODE
      command_str = "transmit_multicast"
      value = value == 1
    when Command::TDU8_PANEL_LOCK
      value = value == 1
    when Command::TDU8_INPUT_SOURCE
      value = InputSource.from_value?(value.to_i) || value
    when Command::TDU8_PRESET
      value = Preset.from_value?(value.to_i) || value
    end

    self[command_str] = value
  end

  @[Security(Level::Administrator)]
  def write(command : Command, value : UInt8 | UInt32 | String)
    body_data = URI::Params.build { |form|
      if channel = channel_number
        form.add "type", "TT_U8"
        form.add "id", "TDU8_CURRENT_CHANNEL"
        form.add "value", channel.to_s
      end
      form.add "type", TYPES[command].to_s
      form.add "id", command.to_s
      form.add "value", value.to_s
    }.to_s

    logger.debug { "updating setting: #{body_data}" }

    response = post("/TBL-WRITE", body: body_data)
    raise "request failed with #{response.status_code}\n#{response.body}" unless response.success?

    set_status(command, value)
  end

  @[Security(Level::Support)]
  def enable_join_code(state : Bool)
    write(Command::TDU8_SECURE_MODE, state ? 1_u8 : 0_u8)
  end

  @[Security(Level::Support)]
  def set_join_code(pin : String)
    write(Command::TDSTR_JOIN_CODE, pin)
  end

  # creates a numeric pin size digits long
  @[Security(Level::Support)]
  def set_random_join_code(size : Int32 = 4)
    pin = String.build do |str|
      size.times do
        rand(9).to_s(str)
      end
    end
    set_join_code(pin)
  end

  @[Security(Level::Support)]
  def reboot
    write(Command::TDU8_REBOOT, 1_u8)
  end

  @[Security(Level::Administrator)]
  def restore_defaults
    write(Command::TDU8_RESTORE_DEFAULTS, 1_u8)
  end

  @[Security(Level::Administrator)]
  def set_vu_meter(value : UInt8, overload : Bool = false)
    value = value.clamp(0_u8, 9_u8) unless overload
    write(Command::TDU8_VU_METER_VALUE, value)
  end

  @[Security(Level::Support)]
  def input_gain(value : UInt8)
    value = value.clamp(0_u8, 50_u8)
    write(Command::TDU8_INPUT_GAIN, value)
  end

  enum InputSource
    AnalogLineIn = 1
    Mic          = 2
    PhantomMic   = 3
    AES          = 4
    S_PDIF       = 5
    TestTone     = 6
  end

  @[Security(Level::Support)]
  def input_source(value : InputSource)
    write(Command::TDU8_INPUT_SOURCE, value.to_u8)
  end

  enum Preset
    Voice         = 1
    Music         = 2
    HearingAssist = 3
    Custom        = 4
  end

  @[Security(Level::Support)]
  def preset(value : Preset)
    write(Command::TDU8_PRESET, value.to_u8)
  end

  @[Security(Level::Administrator)]
  def transmit_multicast(state : Bool)
    write(Command::TDU8_AUDIO_TX_MODE, state ? 1_u8 : 0_u8)
  end

  @[Security(Level::Administrator)]
  def set_ttl(value : UInt8)
    value = value.clamp(0_u8, 30_u8)
    write(Command::TDU8_TTL, value)
  end

  @[Security(Level::Support)]
  def lock_front_panel(state : Bool)
    write(Command::TDU8_PANEL_LOCK, state ? 1_u8 : 0_u8)
  end

  @[Security(Level::Administrator)]
  def set_multicast_address(ip_address : String)
    write(Command::TDSTR_MULTICAST_ADDR, ip_address)
  end
end
