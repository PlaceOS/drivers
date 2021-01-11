require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

# Documentation: https://aca.im/driver_docs/Sharp/pnl601b.pdf
#  also https://aca.im/driver_docs/Sharp/PN_L802B_operation_guide.pdf

class Sharp::PnSeries < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    DVI = 1
    HDMI = 10
    HDMI2 = 13
    HDMI3 = 18
    DisplayPort = 14
    VGA = 2
    VGA2 = 16
    Component = 3

    def to_s
      "INPS" + self.value.to_s.rjust(4, '0')
    end
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  tcp_port 10008
  descriptive_name "Sharp Monitor"
  generic_name :Display

  @volume_min : Int32 = 0
  @volume_max : Int32 = 31
  @brightness_min : Int32 = 0
  @brightness_max : Int32 = 31
  @contrast_min : Int32 = 0
  @contrast_max : Int32 = 60 # multiply by two when VGA selected
  @dbl_contrast : Bool = true
  @model_number : Bool = false

  @vol_status : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil

  DELIMITER = "\x0D\x0A"

  def on_load
    transport.tokenizer = Tokenizer.new(DELIMITER)
  end

  def connected
    # Will be sent after login is requested (config - wait ready)
    send_credentials

    schedule.every(60.seconds) do
      logger.debug { "-- Polling Display" }
      do_poll
    end
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    delay = self[:power_on_delay]?.try(&.as_i) || 5000

    # If the requested state is different from the current state
    if state != !!self[:power]?.try(&.as_bool)
      if state
        logger.debug { "-- Sharp LCD, requested to power on" }
        do_send("POWR   1", name: :POWR)#, timeout: delay + 15000)
        self[:warming] = true
        self[:power] = true
        do_send("POWR????", name: :POWR)#, timeout: 10000) # clears warming
      else
        logger.debug { "-- Sharp LCD, requested to power off" }
        do_send("POWR   0", name: :POWR)#, timeout: 15000)
        self[:power] = false
      end
    end

    mute_status(0)
    volume_status(0)
  end

  def power?(**options)
    do_send("POWR????", **options, name: :POWR).get# timeout: 10000)
    self[:power].as_bool
  end

  # Resets the brightness and contrast settings
  def reset
    do_send("ARST   2")
  end

  def switch_to(input : Input)
    logger.debug { "-- Sharp LCD, requested to switch to: #{input}" }
    do_send(input.to_s, name: :input)#, delay: 2000, timeout: 20000) # does an auto adjust on switch to vga
    self[:input] = input
    brightness_status(40) # higher status than polling commands - lower than input switching (vid then audio is common)
    contrast_status(40)
  end

  AUDIO = {
    audio1: "ASDP   2",
    audio2: "ASDP   3",
    dvi: "ASDP   1",
    dvi_alt: "ASDA   1",
    hdmi: "ASHP   0",
    hdmi_3mm: "ASHP   1",
    hdmi_rca: "ASHP   2",
    vga: "ASAP   1",
    component: "ASCA   1"
  }
  def switch_audio(input : String)
    logger.debug { "-- Sharp LCD, requested to switch audio to: #{input}" }

    do_send(AUDIO[input], name: :audio)
    mute_status(40) # higher status than polling commands - lower than input switching
    volume_status(40) # Mute response requests volume
  end

  def auto_adjust
    do_send("AGIN   1")#, timeout: 20000)
  end

  def brightness(val : Int32)
    do_send("VLMP#{val.clamp(@brightness_min, @brightness_max).to_s.rjust(4, ' ')}")
  end

  def contrast(val : Int32)
    # See Sharp manual
    multiplier = self[:input]? == "VGA" && @dbl_contrast ? 2 : 1
    val = val.clamp(@contrast_min, @contrast_max) * multiplier
    do_send("CONT#{val.to_s.rjust(4, ' ')}")
  end

  def volume(val : Int32)
    @vol_status.try(&.cancel)
    @vol_status = schedule.in(2.seconds) do
      @vol_status = nil
      volume_status
    end

    self[:volume] = val
    self[:audio_mute] = false

    do_send("VOLM#{val.clamp(@volume_min, @volume_max).to_s.rjust(4, ' ')}")
  end

  # Mutes both audio/video
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    logger.debug { "-- Sharp LCD, requested to mute #{state}" }
    do_send("MUTE   #{state ? '1' : '0'}")
    mute_status(50) # High priority mute status
  end

  OPERATION_CODE = {
    video_input: "INPS",
    volume_status: "VOLM",
    mute_status: "MUTE",
    power_on_delay: "PWOD",
    contrast_status: "CONT",
    brightness_status: "VLMP",
    model_number: "INF1"
  }
  {% for name, cmd in OPERATION_CODE %}
    @[Security(Level::Administrator)]
    def {{name.id}}(priority : Int32 = 0, **options)
      data = {{cmd.id.stringify}} + "????"
      logger.debug { "Sharp sending: #{data}" }
      do_send(data, **options, priority: priority) # Status polling is a low priority
    end
  {% end %}

  def do_poll
    if power?
      model_number unless self[:model_number]? # only query the model number if we don't already have it
      power_on_delay
      mute_status
      volume_status
    end
  end

  private def determine_contrast_mode
    # As of 09/2015 only the PN-L802B does not have double contrast on RGB input.
    # All prior models do double the contrast and don't have an L so let's assume it's the L in the model number that determines this for now
    # (we can confirm the logic as more models are released)
    if self[:model_number]? =~ /L/
      self[:dbl_contrast] = false
    end
  end

  private def send_credentials
    do_send(setting?(String?, :username) || "", priority: 100)#, delay: 500, wait: false)
    do_send(setting?(String?, :password) || "", priority: 100)#, delay_on_receive: 1000)
  end

  def received(data, task)
    pp "-- Sharp LCD, received: #{data}"
    data = String.new(data[0..-3])
    logger.debug { "-- Sharp LCD, received: #{data}" }
    pp "-- Sharp LCD, received: #{data}"
    value = nil

    if data == "Password:OK"
      pp "password okay"
      do_poll
    elsif data == "Password:Login incorrect"
      schedule.in(5.seconds) { send_credentials }
      return task.try(&.success("Sharp LCD, bad login or logged off. Attempting login.."))
    elsif data == "OK"
      return task.try(&.success)
    elsif data == "WAIT"
      logger.debug { "-- Sharp LCD, wait" }
      return nil
    elsif data == "ERR"
      return task.try(&.abort("-- Sharp LCD, error"))
    end

    if !(command = task.try(&.name))
      return task.try(&.abort("Sharp sent out of order response: #{data}")) if data.size < 8 # Out of order send?
      command = data[0..3]
      value = data[4..7].to_i
    else
      value = data.to_i
      logger.debug { "setting value ret: #{command}" }
    end

    case command
    when :POWR # Power status
      self[:warming] = false
      self[:power] = value > 0
    when :INPS # Input status
      input = Input.from_value?(value)
      self[:input] = input || "unknown"
      logger.debug { "-- Sharp LCD, input #{self[:input]} == #{value}" }
    when :VOLM # Volume status
      self[:volume] = value unless self[:audio_mute]?.try(&.as_bool)
    when :MUTE # Mute status
      self[:audio_mute] = value == 1
      if value == 1
        self[:volume] = 0
      else
        volume_status(90) # high priority
      end
    when :CONT # Contrast status
      value = value / 2 if self[:input]? == "VGA" && @dbl_contrast
      self[:contrast] = value
    when :VLMP # brightness status
      self[:brightness] = value
    when :PWOD
      self[:power_on_delay] = value
    when :INF1
      self[:model_number] = value
      logger.debug { "-- Sharp LCD, model number #{self[:model_number]}" }
      determine_contrast_mode
    end

    task.try(&.success)
  end

  private def do_send(data, **options)
    pp "sending #{data}"
    send("#{data}#{DELIMITER}", **options)
  end
end
