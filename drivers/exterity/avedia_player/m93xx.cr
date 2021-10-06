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
    channel_details: [
      {
        name:    "Al Jazeera",
        icon:    "https://url-to-svg-or-png",
        channel: "udp://239.192.10.170:5000?hwchan=0",
      },
    ],
  })

  class ChannelDetail
    include JSON::Serializable

    getter name : String
    getter icon : String?
    getter channel : String
  end

  @ready : Bool = false
  @channel_lookup : Hash(String, ChannelDetail) = {} of String => ChannelDetail

  def on_load
    on_update
  end

  def on_update
    channel_lookup = {} of String => ChannelDetail
    if channel_details = setting?(Array(ChannelDetail), :channel_details)
      self[:channel_details] = channel_details
      channel_details.each { |lookup| channel_lookup[lookup.channel] = lookup }
    else
      self[:channel_details] = nil
    end
    @channel_lookup = channel_lookup
  end

  def connected
    self[:ready] = @ready = false

    schedule.every(59.seconds) do
      logger.debug { "-- Polling Exterity Player" }
      tv_info
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

  def stream(uri : String)
    set(:playChannelUri, uri, name: :channel).get
    name = @channel_lookup[uri]?.try &.name

    schedule.in(2.second) do
      current_channel.get
      if name && uri == self[:current_channel]
        channel_name name
      end
    end

    name
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
