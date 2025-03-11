require "telnet"
require "placeos-driver"

class Exterity::AvediaPlayer::R93xx < PlaceOS::Driver
  descriptive_name "Exterity Avedia Player (M93xx)"
  generic_name :IPTV
  tcp_port 22

  default_settings({
    ssh: {
      username: :ctrl,
      password: :labrador,
    },
    max_waits:       100,
  })

  @ready : Bool = false

  def connected
    self[:ready] = @ready = false

    schedule.every(59.seconds) do
      logger.debug { "-- Polling Exterity Player" }
      current_channel
      current_channel_name
    end

    schedule.every(1.hour) do
      logger.debug { "-- Polling Exterity Player" }
      dump
    end
  end

  def disconnected
    self[:ready] = @ready = false
    transport.tokenizer = nil
    schedule.clear
  end

  def channel(number : Int32 | String)
    if number.is_a? Number
      set :playChannelNumber, number, name: :channel
    else
      stream number
    end
  end

  def channel_name(name : String)
    set(:currentChannel_name, name, name: :name).get
    current_channel_name
  end

  def stream(uri : String) : Nil
    set(:playChannelUri, uri, name: :channel).get
    schedule.in(2.second) do
      current_channel
      current_channel_name
    end
  end

  def current_channel
    get :currentChannel
  end

  def current_channel_name
    get :currentChannel_name
  end

  def dump
    do_send "^dump!\r", name: :dump
  end

  def help
    do_send "^help!\r", name: :help
  end

  def reboot
    remote :reboot
  end

  def tv_info
    get :tv_info
  end

  def version
    get :SoftwareVersion
  end

  @[Security(Level::Support)]
  def manual(cmd : String)
    do_send cmd
  end

  def received(data, task)
    data = String.new(data).strip

    logger.debug { "Exterity sent #{data}" }

    if !@ready && data =~ /Terminal Control Interface/i
      logger.info { "-- got the control interface message, we're READY now" }
      transport.tokenizer = Tokenizer.new("!")
      self[:ready] = @ready = true
      dump
      return
    end

    # Extract response between the ^ and !
    resp = data.split("^")[1][0..-2]
    process_resp resp, task
  end

  protected def process_resp(data, task)
    logger.debug { "Resp details #{data}" }

    parts = data.split ':', 2

    case parts[0]
    when "error"
      message = task ? "Error when requesting: #{task.try &.name}" : "Error response received"
      logger.warn { message }
      task.try &.abort(message)
    else
      self[parts[0].underscore] = parts[1]
      task.try &.success(parts[1])
    end
  end

  protected def do_send(command, **options)
    logger.debug { "requesting #{command}" }
    send command, **options
  end

  protected def set(command, data, **options)
    do_send "^set:#{command}:#{data}!\r", **options.merge({wait: false})
  end

  protected def remote(cmd, **options)
    do_send "^send:#{cmd}!\r", **options
  end

  protected def get(status, **options)
    do_send "^get:#{status}!\r", **options
  end
end
