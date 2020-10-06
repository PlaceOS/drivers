require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

class Lg::Displays::Ls5 < PlaceOS::Driver
  include Interface::Powerable
  # include Interface::Muteable

  enum Input
    Dvi            = 0x70
    Hdmi           = 0xA0
    HdmiDtv        = 0x90
    Hdmi2          = 0xA1
    Hdmi2Dtv       = 0x91
    DisplayPort    = 0xD0
    DisplayPortDtv = 0xC0
  end
  include PlaceOS::Driver::Interface::InputSelection(Input)

  # Discovery Information
  tcp_port 9761
  descriptive_name "LG WebOS LCD Monitor"
  generic_name :Display
  # This device does not hold the connection open. Must be configured as makebreak
  makebreak!

  default_settings({
    rs232_control: false,
    display_id: 1,
    autoswitch: false
  })

  @display_id : Int32 = 0
  @id_num : Int32 = 1
  @rs232 : Bool = false
  @autoswitch : Bool = false
  @id : String = ""

  DELIMITER = 0x78_u8 # 'x'

  def on_load
    # Communication settings
    queue.delay = 150.milliseconds
    transport.tokenizer = Tokenizer.new(Bytes[DELIMITER])
    on_update
  end

  def on_update
    @rs232 = setting(Bool, :rs232_control)
    @id_num = setting(Int32, :display_id)
    @autoswitch = setting(Bool, :autoswitch)
    @id = @id_num.to_s.rjust(2, '0')
  end

  def connected
    # #configure_dpm
    # wake_on_lan(true)
    # no_signal_off(false)
    # auto_off(false)
    # local_button_lock(true)
    # pm_mode(3)
    # schedule.every(50.seconds, true) do
    #   do_poll
    # end
  end

  def disconnected
    schedule.clear
    # self[:power] = false  # As we may need to use wake on lan
    # self[:power_stable] = false if !self[:power_target].nil? && self[:power_target] != self[:power]
  end

  enum Command
    Power           = 0x61 # 'a'
    Input           = 0x62 # 'b'
    AspectRatio     = 0x63 # 'c'
    ScreenMute      = 0x64 # 'd'
    VolumeMute      = 0x65 # 'e'
    Volume          = 0x66 # 'f'
    Contrast        = 0x67 # 'g'
    Brightness      = 0x68 # 'h'
    Dpm             = 0x69 # 'j'
    Sharpness       = 0x6B # 'k'
    AutoOff         = 0x6E # 'n'
    LocalButtonLock = 0x6F # 'o'
    Wol             = 0x77 # 'w'
    # Dupe with Contrast
    # NoSignalOff: 'g'
    # Dupe with AutoOff
    # PmMode          = 0x 'n'
  end

  def power(state : Bool)
    if state
      if @rs232
        do_send(Command::Power, 1, name: :power, priority: 99)
      else
        # wake(broadcast)
      end
    end
  end

  def hard_off
    do_send(Command::Power, 0, name: :power, priority: 99)
  end

  def switch_to(input : Input, **options)
    do_send(Command::Input, input.value, 'x', name: :input, delay_on_receive: 2000)
  end

  def received(data, task)
  end

  private def do_send(command : Command, data : Int, system : Char = 'k', **options)
  end
end
