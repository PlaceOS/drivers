require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

# Documentation: https://aca.im/driver_docs/Sharp/pnl601b.pdf
#  also https://aca.im/driver_docs/Sharp/PN_L802B_operation_guide.pdf

class Sharp::PnSeries < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  enum Input
    DVI         =  1
    HDMI        = 10
    HDMI2       = 13
    HDMI3       = 18
    DisplayPort = 14
    VGA         =  2
    VGA2        = 16
    Component   =  3

    def data
      "INPS" + self.value.to_s.rjust(4, '0')
    end
  end

  include Interface::InputSelection(Input)

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
    delay = self[:power_on_delay]?.try(&.as_i) || 5

    # If the requested state is different from the current state
    if state != !!self[:power]?.try(&.as_bool)
      if state
        logger.debug { "-- Sharp LCD, requested to power on" }
        do_send("POWR   1", name: :POWR, timeout: delay.seconds + 15.seconds)
        self[:warming] = true
        self[:power] = true
        do_send("POWR????", name: :POWR, timeout: 10.seconds) # clears warming
      else
        logger.debug { "-- Sharp LCD, requested to power off" }
        do_send("POWR   0", name: :POWR, timeout: 15.seconds)
        self[:power] = false
      end
    end

    power?
    mute_status(0)
    volume_status(0)
  end

  def power?(**options)
    do_send("POWR????", **options, name: :POWR, timeout: 10.seconds).get
    self[:power].as_bool
  end

  # Resets the brightness and contrast settings
  def reset
    do_send("ARST   2")
  end

  def switch_to(input : Input)
    logger.debug { "-- Sharp LCD, requested to switch to: #{input}" }
    do_send(input.data, name: :input, delay: 2.seconds, timeout: 20.seconds).get # does an auto adjust on switch to vga
    video_input(40)
    brightness_status(40) # higher status than polling commands - lower than input switching (vid then audio is common)
    contrast_status(40)
  end

  AUDIO = {
    audio1:    "ASDP   2",
    audio2:    "ASDP   3",
    dvi:       "ASDP   1",
    dvi_alt:   "ASDA   1",
    hdmi:      "ASHP   0",
    hdmi_3mm:  "ASHP   1",
    hdmi_rca:  "ASHP   2",
    vga:       "ASAP   1",
    component: "ASCA   1",
  }
  AUDIO_RESPONSE = AUDIO.to_h.invert

  def switch_audio(input : String)
    logger.debug { "-- Sharp LCD, requested to switch audio to: #{input}" }

    do_send(AUDIO[input], name: "audio")
    mute_status(40)   # higher status than polling commands - lower than input switching
    volume_status(40) # Mute response requests volume
  end

  def auto_adjust
    do_send("AGIN   1", timeout: 20.seconds)
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
    do_send("VOLM#{val.clamp(@volume_min, @volume_max).to_s.rjust(4, ' ')}")
  end

  # There seems to only be audio mute available
  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    if layer == MuteLayer::Video
      logger.warn { "Sharp LCD requested to mute video which is unsupported" }
    else
      logger.debug { "Sharp LCD, requested to mute #{state}" }
      do_send("MUTE   #{state ? '1' : '0'}")
      mute_status(50) # High priority mute status
    end
  end

  OPERATION_CODE = {
    video_input:       "INPS",
    volume_status:     "VOLM",
    mute_status:       "MUTE",
    power_on_delay:    "PWOD",
    contrast_status:   "CONT",
    brightness_status: "VLMP",
    model_number:      "INF1",
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
    end
  end

  private def determine_contrast_mode
    # As of 09/2015 only the PN-L802B does not have double contrast on RGB input.
    # All prior models do double the contrast and don't have an L so let's assume it's the L in the model number that determines this for now
    # (we can confirm the logic as more models are released)
    @dbl_contrast = false if self[:model_number].as_s.includes?('L')
    logger.debug { "dbl_contrast is #{@dbl_contrast}" }
  end

  private def send_credentials
    do_send(setting?(String?, :username) || "", priority: 100, delay: 500.milliseconds) # , wait: false)
    # TODO: figure out equivalent in crystal for delay_on_receive
    do_send(setting?(String?, :password) || "", priority: 100) # , delay_on_receive: 1000)
  end

  def received(data, task)
    data = String.new(data[0..-3])
    logger.debug { "-- Sharp LCD, received: #{data}" }

    if data == "Password:OK"
      return task.try(&.success("Login successful"))
    elsif data == "Password:Login incorrect"
      schedule.in(5.seconds) { send_credentials }
      return task.try(&.success("Sharp LCD, bad login or logged off. Attempting login.."))
    elsif data == "OK"
      return task.try(&.success)
    elsif data == "WAIT"
      logger.debug { "-- Sharp LCD, wait" }
      return
    elsif data == "ERR"
      return task.try(&.abort("-- Sharp LCD, error"))
    elsif data.size < 8 # Out of order send?
      return task.try(&.abort("Sharp sent out of order response: #{data}"))
    end

    command, value = data.split

    case command
    when "POWR" # Power status
      self[:warming] = false
      self[:power] = value.to_i > 0
    when "INPS" # Input status
      input = Input.from_value?(value.to_i)
      self[:input] = input || "unknown"
      logger.debug { "-- Sharp LCD, input #{self[:input]} == #{value}" }
    when "VOLM" # Volume status
      self[:volume] = value.to_i unless self[:audio_mute]?.try(&.as_bool)
    when "MUTE" # Mute status
      self[:audio_mute] = (mute = value.to_i == 1)
      if mute
        self[:volume] = 0
      else
        volume_status(90) # high priority
      end
    when "CONT" # Contrast status
      self[:contrast] = value.to_i / (self[:input]? == "VGA" && @dbl_contrast ? 2 : 1)
    when "VLMP" # brightness status
      self[:brightness] = value.to_i
    when "PWOD"
      self[:power_on_delay] = value.to_i
    when "INF1"
      self[:model_number] = value
      logger.debug { "-- Sharp LCD, model number #{self[:model_number]}" }
      determine_contrast_mode
    when "ASDP", "ASDA", "ASHP", "ASAP", "ASCA" # audio switching commands
      self[:audio_input] = AUDIO_RESPONSE[data] || "unknown"
    end

    task.try(&.success)
  end

  private def do_send(data, delay = 100.milliseconds, **options)
    send("#{data}#{DELIMITER}", **options, delay: delay)
  end
end
