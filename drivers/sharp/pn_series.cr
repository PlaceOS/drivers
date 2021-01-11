class Sharp::PnSeries < PlaceOS::Driver
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

  def on_load
    transport.tokenizer = Tokenizer.new("\x0D\x0A")
    on_update
  end

  def on_update
    @volume_min = 0
    @volume_max = 31
    @brightness_min = 0
    @brightness_max = 31
    @contrast_min = 0
    @contrast_max = 60 # multiply by two when VGA selected
    @dbl_contrast = true
    @model_number = false
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
        do_send("POWR????")#, value_ret_only: :POWR, timeout: 10000) # clears warming
      else
        logger.debug { "-- Sharp LCD, requested to power off" }
        do_send("POWR   0", name: :POWR)#, timeout: 15000)
        self[:power] = false
      end
    end

    # mute_status(0)
    # volume_status(0)
  end

  def power?(**options)
    do_send("POWR????", **options)#, value_ret_only: :POWR, timeout: 10000)
  end

  # Resets the brightness and contrast settings
  def reset
    do_send("ARST   2")
  end

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

  def switch_to(input : Input)
    logger.debug { "-- Sharp LCD, requested to switch to: #{input}" }
    do_send(input.to_s, name: :input)#, delay: 2000, timeout: 20000) # does an auto adjust on switch to vga
    self[:input] = input
    # brightness_status(40) # higher status than polling commands - lower than input switching (vid then audio is common)
    # contrast_status(40)
  end

  def send_credentials
  end

  def do_poll
  end

  private def do_send(data, **options)
    send("#{data}\x0D", **options)
  end

  def received(data, task)
    task.try &.success
  end
end
