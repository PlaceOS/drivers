require "telnet"
require "placeos-driver"

class Exterity::AvediaPlayer::R93xx < PlaceOS::Driver
  descriptive_name "Exterity Avedia Player (R93xx)"
  generic_name :IPTV
  tcp_port 23

  default_settings({
    max_waits: 100,
    username:  "admin",
    password:  "labrador",
  })

  @ready : Bool = false

  def on_load
    new_telnet_client
    transport.pre_processor { |bytes| @telnet.try &.buffer(bytes) }
  end

  def connected
    @ready = false
    self[:ready] = false

    schedule.every(60.seconds) do
      logger.debug { "-- Polling Exterity Player" }
      tv_info
    end
  end

  def disconnected
    # Ensures the buffer is cleared
    new_telnet_client

    schedule.clear
  end

  def channel(number : Int32 | String)
    if number.is_a? Number
      set :playChannelNumber, number
    else
      stream number
    end
  end

  def stream(uri : String)
    set :playChannelUri, uri
  end

  def dump
    do_send "^dump!", name: :dump
  end

  def help
    do_send "^help!", name: :help
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

  def manual(cmd : String)
    do_send cmd
  end

  def received(data, task)
    data = String.new(data).strip

    logger.debug { "Exterity sent #{data}" }

    if @ready
      # Extract response
      data.split("!").map(&.strip("^")).each do |resp|
        process_resp(resp, task)
      end
    elsif data =~ /Terminal Control Interface/i
      @ready = true
      self[:ready] = true
      version
    elsif data =~ /login:/i
      transport.tokenizer = Tokenizer.new("\r")

      # Login
      do_send setting(String, :username), wait: false, delay: 2.seconds, priority: 98
      do_send setting(String, :password), wait: false, delay: 2.seconds, priority: 97

      # We need to disconnect if we don't see the serialCommandInterface after a certain amount of time
      schedule.in(5.seconds) do
        if !@ready
          logger.error { "Exterity connection failed to be ready after 5 seconds. Check username and password." }
          disconnect
        end
      end
    end

    task.try &.success
  end

  protected def process_resp(data, task)
    logger.debug { "Resp details #{data}" }

    parts = data.split ':'

    case parts[0].to_s
    when "error"
      if task != nil
        logger.warn { "Error when requesting: #{task.try &.name}" }
      else
        logger.warn { "Error response received" }
      end
    when "tv_info"
      self[:tv_info] = parts[1]
    when "SoftwareVersion"
      self[:version] = parts[1]
    end
  end

  protected def new_telnet_client
    @telnet = Telnet.new do |data|
      transport.send(data)
    end
  end

  protected def do_send(command, **options)
    logger.debug { "requesting #{command}" }
    send @telnet.not_nil!.prepare(command), **options
  end

  protected def set(command, data, **options)
    # options[:name] = :"set_#{command}" unless options[:name]
    do_send "^set:#{command}:#{data}!", **options
  end

  protected def remote(cmd, **options)
    do_send "^send:#{cmd}!", **options
  end

  protected def get(status, **options)
    do_send "^get:#{status}!", **options
  end
end
