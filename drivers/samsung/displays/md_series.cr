module Samsung; end

# Documentation: https://drive.google.com/a/room.tools/file/d/135yRevYnI6BbZvRWjV51Ur0yKU5bQ_a-/view?usp=sharing
# Older Documentation: https://aca.im/driver_docs/Samsung/MDC%20Protocol%202015%20v13.7c.pdf

class Samsung::Displays::MdSeries < PlaceOS::Driver
  # Discovery Information
  tcp_port 1515
  descriptive_name "Samsung MD, DM & QM Series LCD"
  generic_name :Display

  # Markdown description
  description <<-DESC
  For DM displays configure the following 1:

  1. Network Standby = ON
  2. Set Auto Standby = OFF
  3. Set Eco Solution, Auto Off = OFF

  Hard Power off displays each night and hard power ON in the morning.
  DESC

  default_settings({
    display_id: 0,
  })

  @blank : String = ""

  # TODO: figure out how to define indicator \xAA
  def init_tokenizer
    @buffer = Tokenizer.new do |io|
      # bytes = io.peek # for demonstration purposes
      string = io.gets_to_end

      # (data length + header and checksum)
      string[2].to_i + 4
    end
  end

  def on_load
    transport.tokenizer = init_tokenizer
    on_update

    self[:volume_min] = 0
    self[:volume_max] = 100

    # Meta data for inquiring interfaces
    self[:type] = :lcd
    self[:input_stable] = true
    self[:input_target] ||= :hdmi
    self[:power_stable] = true
  end

  def on_update
    @id = setting(Int32?, :display_id) || 0
    @rs232 = setting(Bool?, :rs232_control) || false
    @blank = setting(String, :blank)
  end

  def connected
    do_poll
    do_device_config unless self[:hard_off]

    schedule.every(30.seconds) do
      logger.debug { "-- polling display" }
      do_poll
    end
  end

  def disconnected
    self[:power] = false unless @rs232
    schedule.clear
  end

  enum COMMANDS
    Status           = 0x00
    Hard_off         = 0x11 # Completely powers off
    Panel_mute       = 0xF9 # Screen blanking / visual mute
    Volume           = 0x12
    Contrast         = 0x24
    Brightness       = 0x25
    Sharpness        = 0x26
    Colour           = 0x27
    Tint             = 0x28
    Red_gain         = 0x29
    Green_gain       = 0x2A
    Blue_gain        = 0x2B
    Input            = 0x14
    Mode             = 0x18
    Size             = 0x19
    Pip              = 0x3C # picture in picture
    Auto_adjust      = 0x3D
    Wall_mode        = 0x5C # Video wall mode
    Safety           = 0x5D
    Wall_on          = 0x84 # Video wall enabled
    Wall_user        = 0x89 # Video wall user control
    Speaker          = 0x68
    Net_standby      = 0xB5 # Keep NIC active in standby
    Eco_solution     = 0xE6 # Eco options (auto power off)
    Auto_power       = 0x33
    Screen_split     = 0xB2 # Tri / quad split (larger panels only)
    Software_version = 0x0E
    Serial_number    = 0x0B
  end

  # As true power off disconnects the server we only want to
  # power off the panel. This doesn't work in video walls
  # so if a nominal blank input is
  # TODO: check type for broadcast is correct
  def power(power : Bool, broadcast : String? = nil)
    self[:power_target] = power
    self[:power_stable] = false

    if !power
      # Blank the screen before turning off panel if required
      # required by some video walls where screens are chained
      switch_to(@blank) if @blank && self[:power]
      do_send("panel_mute", 1)
    elsif !@rs232 && !self[:connected]
       wake(broadcast)
    else
      # Power on
      do_send("hard_off", 1)
      do_send("panel_mute", 0)
    end
  end

  def hard_off
    do_send("panel_mute", 0) if self[:power]
    do_send("hard_off", 0)
    do_poll
  end

  # TODO: figure out what block is for
  # def power?(**options, &block)
  def power?(**options)
    # options[:emit] = block unless block.nil?
    do_send("panel_mute", [] of Int32, **options)
  end

  # Adds mute states compatible with projectors
  def mute(state : Bool = true)
    power(!state)
  end

  def unmute
    power(true)
  end

  # check software version
  def software_version?
    do_send("software_version")
  end

  def serial_number?
    do_send("serial_number")
  end

  # # ability to send custom mdc commands via backoffice
  # def custom_mdc(command, value = "")
  #   do_send(hex_to_byte(command).bytes[0], hex_to_byte(value).bytes)
  # end

  # def set_timer(enable = true, volume = 0)
  #   # set the time on the display
  #   time_cmd = 0xA7
  #   time_request = [] of Int
  #   t = Time.now
  #   time_request << t.day
  #   hour = t.hour
  #   ampm = if hour > 12
  #            hour = hour - 12
  #            0 # pm
  #          else
  #            1 # am
  #          end
  #   time_request << hour
  #   time_request << t.min
  #   time_request << t.month
  #   year = t.year.to_s(16).rjust(4, "0")
  #   time_request << year[0..1].to_i(16)
  #   time_request << year[2..-1].to_i(16)
  #   time_request << ampm

  #   do_send time_cmd, time_request

  #   state = is_affirmative?(enable) ? "01" : "00"
  #   vol = volume.to_s(16).rjust(2, "0")
  #   #              on 03:45 am enabled  off 03:30 am enabled  on-everyday  ignore manual  off-everyday  ignore manual  volume 15  input HDMI   holiday apply
  #   custom_mdc(
  #     "A4",
  #     "03-2D-01 #{state}  03-1E-01   #{state}      01          80               01           80          #{vol}        21          01"
  #   )
  # end

  enum INPUTS
    Vga           = 0x14 # pc in manual
    Dvi           = 0x18
    Dvi_video     = 0x1F
    Hdmi          = 0x21
    Hdmi_pc       = 0x22
    Hdmi2         = 0x23
    Hdmi2_pc      = 0x24
    Hdmi3         = 0x31
    Hdmi3_pc      = 0x32
    Hdmi4         = 0x33
    Hdmi4_pc      = 0x34
    Display_port  = 0x25
    Dtv           = 0x40
    Media         = 0x60
    Widi          = 0x61
    Magic_info    = 0x20
    Whiteboard    = 0x64
  end

  def switch_to(input : String, **options)
    self[:input_stable] = false
    self[:input_target] = input
    do_send("input", INPUTS.parse(input).value, **options)
  end

  # # TODO: check if used anywhere
  # enum SCALE_MODE
  #   fill = 0x09
  #   fit =  0x20
  # end

  # # Activite the internal compositor. Can either split 3 or 4 ways.
  # def split(inputs = [:hdmi, :hdmi2, :hdmi3], layout = 0, scale = :fit, **options)
  #   main_source = inputs.shift

  #   data = [
  #     1,                  # enable
  #     0,                  # sound from screen section 1
  #     layout,             # layout mode (1..6)
  #     SCALE_MODE[scale],  # scaling for main source
  #     inputs.flat_map do |input|
  #       input = input.to_sym if input.is_a? String
  #       [INPUTS[input], SCALE_MODE[scale]]
  #     end
  #   ].flatten

  #   switch_to(main_source, options).then do
  #     do_send("screen_split", data, options)
  #   end
  # end

  def in_range(val : Int32, max : Int32) : Int32
    min = 0
    if val < min
      val = min
    elsif val > max
      val = max
    end
    val
  end

  def volume(vol : Int32, **options)
    vol = in_range(vol, 100)
    do_send("volume", vol, **options)
  end

  # Emulate mute
  def mute_audio(val : Bool = true)
    if val
      if !self[:audio_mute]
        self[:audio_mute] = true
        self[:previous_volume] = self[:volume].as_i? || 50
        volume(0)
      end
    else
      unmute_audio
    end
  end

  def unmute_audio
    if self[:audio_mute]
      self[:audio_mute] = false      
      volume(self[:previous_volume].as_i? || 50)
    end
  end

  enum SPEAKERMODES
    Internal = 0
    External = 1
  end

  def speaker_select(mode : String, **options)
    do_send("speaker", SPEAKERMODES.parse(mode).value, **options)
  end

  def do_poll
    do_send("status", [] of Int32, priority: 0)
    power? unless self[:hard_off]
  end

  # Enable power on (without WOL)
  def network_standby(enable : Bool, **options)
    state = enable ? 1 : 0
    do_send("net_standby", state, **options)
  end

  # Eco auto power off timer
  def auto_off_timer(enable : Bool, **options)
    state = enable ? 1 : 0
    do_send("eco_solution", [0x81, state], **options)
  end

  # Device auto power control (presumably signal based?)
  def auto_power(enable : Bool, **options)
    state = enable ? 1 : 0
    do_send("auto_power", state, **options)
  end

  # TODO: figure out this does and port to Crystal
  # # Colour control
  # [
  #   :contrast,
  #   :brightness,
  #   :sharpness,
  #   :colour,
  #   :tint,
  #   :red_gain,
  #   :green_gain,
  #   :blue_gain
  # ].each do |command|
  #   define_method command do |val, **options|
  #     val = in_range(val.to_i, 100)
  #     do_send(command, val, options)
  #   end
  # end

  DEVICE_SETTINGS = [
    "network_standby",
    "auto_off_timer",
    "auto_power",
    "contrast",
    "brightness",
    "sharpness",
    "colour",
    "tint",
    "red_gain",
    "green_gain",
    "blue_gain",
]

  def do_device_config
    logger.debug { "Syncronising device state with settings" }
    DEVICE_SETTINGS.each do |name|
      value = setting(Int32, name)
      # TODO: find out if these are equivalent
      # __send__(name, value) unless value.nil?
      do_send(name, value) unless value.nil?
    end
  end

  # TODO: check type for broadcast is correct
  def wake(broadcast : String? = nil)
    mac = setting(String, :mac_address)
    if mac
      # config is the database model representing this device
      wake_device(mac, broadcast)
      info = "Wake on Lan for MAC #{mac}"
      info += " directed to VLAN #{broadcast}" if broadcast
      logger.debug { info }
    else
      logger.debug { "No MAC address provided" }
    end
  end

  enum RESPONSESTATUS
    Ack = 0x41
    Nak = 0x4e
  end

  def received(data, task)
    logger.debug { "Samsung sent: #{data}" }
  end

  def check_power_state
    return if self[:power_stable]
    if self[:power] == self[:power_target]
      self[:power_stable] = true
    else
      power(self[:power_target].as_bool)
    end
  end

  private def do_send(command : String, data : Int32 | Array = [] of Int32, **options)
    data = [data] if data.is_a?(Int32)

    # options[:name] = command if data.length > 0 # name unless status request
    command = COMMANDS.parse(command)

    # data = [command, @id, data.length] + data # Build request
    # data << (data.reduce(:+) & 0xFF)          # Add checksum
    # data = [0xAA] + data                      # Add header

  #   logger.debug { "Sending to Samsung: #{byte_to_hex(array_to_str(data))}" }

  #   send(array_to_str(data), options).catch do |reason|
  #     disconnect
  #     thread.reject(reason)
  #   end
  end
end
