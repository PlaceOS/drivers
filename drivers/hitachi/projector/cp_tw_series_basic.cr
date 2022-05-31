require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"

class Hitachi::Projector::CpTwSeriesBasic < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  # Discovery Information
  tcp_port 23
  descriptive_name "Hitachi CP-TW Projector (no auth)"
  generic_name :Display

  @recover_power : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
  @recover_input : PlaceOS::Driver::Proxy::Scheduler::TaskWrapper? = nil
  # nil by default (allows manual on and off)
  @power_target : Bool? = nil
  @input_target : Input? = nil

  def on_load
    # Response time is slow
    # and as a make break device it may take time
    # to actually setup the connection with the projector
    queue.delay = 100.milliseconds
    queue.timeout = 5.seconds
    queue.retries = 3

    # Meta data for inquiring interfaces
    self[:type] = :projector
  end

  def connected
    schedule.every(50.seconds, true) { poll_1 }
    schedule.every(10.minutes, true) { poll_2 }
  end

  def poll_1
    power?(priority: 0).get
    if self[:power]?.try &.as_bool
      input?(priority: 0)
      audio_mute?(priority: 0)
      video_mute?(priority: 0)
      freeze?(priority: 0)
    end
  end

  def poll_2
    lamp?(priority: 0)
    filter?(priority: 0)
    error?(priority: 0)
  end

  def disconnected
    schedule.clear
    @recover_power = nil
    @recover_input = nil
  end

  def power(state : Bool)
    @power_target = state
    if state
      logger.debug { "requested to power on" }
      do_send(:power_on)
    else
      logger.debug { "requested to power off" }
      do_send(:power_off)
    end
    power?
  end

  def switch_to(input : Input)
    @input_target = input
    do_send(input.to_s.downcase)
    input?
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo
  )
    mute_video(state) if layer.video? || layer.audio_video?
    mute_audio(state) if layer.audio? || layer.audio_video?
  end

  def mute_video(state : Bool = true)
    if state
      do_send(:mute_video)
    else
      do_send(:unmute_video)
    end
    video_mute?
  end

  def mute_audio(state : Bool = true)
    if state
      do_send(:mute_audio)
    else
      do_send(:unmute_audio)
    end
    audio_mute?
  end

  def lamp_hours_reset
    do_send(:lamp_hours_reset)
    lamp?
  end

  def filter_hours_reset
    do_send(:filter_hours_reset)
    filter?
  end

  enum Response
    Ack   = 0x06
    Nak   = 0x15
    Error = 0x1c
    Data  = 0x1d
    Busy  = 0x1f
  end

  enum Input
    Hdmi    = 0x03
    Hdmi2   = 0x0d
    HdbaSet = 0x11
  end

  enum Error
    Normal
    Cover
    Fan
    Lamp
    Temp
    AirFlow
    Cold
    Filter
  end

  def received(data, task)
    logger.debug { "received 0x#{data}" }
    command = task.try &.name

    case Response.from_value(data[0])
    when .ack?
      task.try &.success
    when .nak?
      task.try &.abort("NAK response")
    when .error?
      task.try &.abort("Error response")
    when .data?
      if command
        case command
        when "power?"
          self[:power] = data[1] == 1
          self[:cooling] = data[1] == 2

          if self[:power]? == @power_target
            @power_target = nil
          elsif @power_target && @recover_power.nil?
            logger.debug { "recovering power state #{self[:power]} != target #{@power_target}" }
            @recover_power = schedule.in(3.seconds) do
              @recover_power = nil
              power(@power_target.not_nil!)
            end
          end
        when "input?"
          input = Input.from_value?(data[1])
          self[:input] = input || "unknown"
          if @input_target
            if input == @input_target
              @input_target = nil
            elsif @recover_input.nil?
              logger.debug { "recovering input #{self[:input]} != target #{@input_target}" }
              @recover_input = schedule.in(3.seconds) do
                @recover_input = nil
                switch_to(@input_target.not_nil!)
              end
            end
          end
        when "error?"
          self[:error_status] = Error.from_value?(data[1]) || "unknown"
        when "freeze?"
          self[:frozen] = data[1] == 1
        when "audio_mute?"
          self[:audio_mute] = data[1] == 1
        when "video_mute?"
          self[:video_mute] = data[1] == 1
        when "lamp?"
          self[:lamp] = data[1] * data[2]
        when "filter?"
          self[:filter] = data[1] * data[2]
        end
        task.try &.success
      else
        task.try &.abort("data received for unknown command")
      end
    when .busy?
      if data[1] == 4 && data[2] == 0
        task.try &.abort("authentication enabled, please disable")
      else
        task.try &.retry("projector busy, retrying")
      end
    end
  end

  # Note: commands have spaces in between each byte for readability
  Commands = {
    # SetRequests
    power_on:           "BA D2 01 00 00 60 01 00",
    power_off:          "2A D3 01 00 00 60 00 00",
    hdmi:               "0E D2 01 00 00 20 03 00",
    hdmi2:              "6E D6 01 00 00 20 0D 00",
    mute_video:         "6E F1 01 00 A0 20 01 00",
    unmute_video:       "FE F0 01 00 A0 20 00 00",
    mute_audio:         "D6 D2 01 00 02 20 01 00",
    unmute_audio:       "46 D3 01 00 02 20 00 00",
    lamp_hours_reset:   "58 DC 06 00 30 70 00 00",
    filter_hours_reset: "98 C6 06 00 40 70 00 00",
    # GetRequests
    power?:      "19 D3 02 00 00 60 00 00",
    input?:      "CD D2 02 00 00 20 00 00",
    error?:      "D9 D8 02 00 20 60 00 00",
    freeze?:     "B0 D2 02 00 02 30 00 00",
    audio_mute?: "75 D3 02 00 02 20 00 00",
    video_mute?: "CD F0 02 00 A0 20 00 00",
    lamp?:       "C2 FF 02 00 90 10 00 00",
    filter?:     "C2 F0 02 00 A0 10 00 00",
  }

  GetRequests = %i(power? input? error? freeze? audio_mute? video_mute? lamp? filter?)
  {% for name in GetRequests %}
    @[Security(Level::Administrator)]
    def {{name.id}}(**options)
      do_send({{name.id.stringify}}, **options)
    end
  {% end %}

  private def do_send(cmd, **options)
    data = "BEEF030600 #{Commands[cmd]}"
    logger.debug { "requesting \"0x#{data}\" name: #{cmd}" }
    # Remove spaces that have been added for readability
    send(data.delete(' ').hexbytes, **options, name: cmd)
  end
end
