module Samsung; end

# Documentation: https://drive.google.com/a/room.tools/file/d/135yRevYnI6BbZvRWjV51Ur0yKU5bQ_a-/view?usp=sharing
# Older Documentation: https://aca.im/driver_docs/Samsung/MDC%20Protocol%202015%20v13.7c.pdf

class Samsung::Displays::MdSeries < PlaceOS::Driver
  # Discovery Information
  tcp_port 1515
  descriptive_name 'Samsung MD, DM & QM Series LCD'
  generic_name :Display

  # Markdown description
  description <<-DESC
  For DM displays configure the following options:

  1. Network Standby = ON
  2. Set Auto Standby = OFF
  3. Set Eco Solution, Auto Off = OFF

  Hard Power off displays each night and hard power ON in the morning.
  DESC

  default_settings({
    display_id: 0
  })

  # TODO: figure out how to define indicator \xAA
  def init_tokenizer
    buffer = Tokenizer.new do |io|
      bytes = io.peek # for demonstration purposes
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
    @id = setting(:display_id) || 0
    @rs232 = setting(:rs232_control) || false
    @blank = setting(:blank)
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

  CMD = Hash(Symbol | Int32, Symbol | Int32) {
    :status => 0x00,
    :hard_off => 0x11,      # Completely powers off
    :panel_mute => 0xF9,    # Screen blanking / visual mute
    :volume => 0x12,
    :contrast => 0x24,
    :brightness => 0x25,
    :sharpness => 0x26,
    :colour => 0x27,
    :tint => 0x28,
    :red_gain => 0x29,
    :green_gain => 0x2A,
    :blue_gain => 0x2B,
    :input => 0x14,
    :mode => 0x18,
    :size => 0x19,
    :pip => 0x3C,           # picture in picture
    :auto_adjust => 0x3D,
    :wall_mode => 0x5C,     # Video wall mode
    :safety => 0x5D,
    :wall_on => 0x84,       # Video wall enabled
    :wall_user => 0x89,     # Video wall user control
    :speaker => 0x68,
    :net_standby => 0xB5,   # Keep NIC active in standby
    :eco_solution => 0xE6,  # Eco options (auto power off)
    :auto_power => 0x33,
    :screen_split => 0xB2,  # Tri / quad split (larger panels only)
    :software_version => 0x0E,
    :serial_number => 0x0B
  }
  CMD.merge!(CMD.invert)
end
