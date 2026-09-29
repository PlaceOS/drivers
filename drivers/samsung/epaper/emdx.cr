require "placeos-driver"
require "placeos-driver/interface/standby_image"
require "base64"
require "http/client"
require "http/server"
require "openssl"
require "socket"
require "uuid"
require "./emdx_models"

# Samsung Color E-Paper (EMDX series)
#
# Control is Samsung MDC over TLS on TCP 1515, authenticated with the display's PIN.
# The display pulls content: command 0xC7 gives it the URL of a JSON manifest, and it
# then downloads the manifest and the picture it names over HTTP.
#
# MDC reference: https://github.com/vgavro/samsung-mdc
# E-Paper content: https://github.com/WeeJeWel/node-samsung-emdx
class Samsung::Epaper::EMDX < PlaceOS::Driver
  include Interface::StandbyImage

  descriptive_name "Samsung Color E-Paper"
  generic_name :EPaper
  description <<-DESC
    Samsung Color E-Paper displays: EM13DX and EM32DX.

    In the Samsung E-Paper app, set the display's content source to Mobile and turn on
    Network Standby so the display stays reachable. Set `pin` to the PIN shown on the
    display during setup.

    The display downloads each picture over HTTP from this driver on `content_port`, so the
    host running the driver must accept connections on that port from the display.
    Set `content_base_url` when the display reaches the driver at a different address,
    for example through NAT.
    DESC

  tcp_port 1515
  makebreak!

  default_settings({
    pin:               "",
    content_port:      6869,
    download_timeout:  60,
    _content_base_url: "http://192.168.0.10:6869",
  })

  MAX_IMAGE_BYTES = 20 * 1024 * 1024
  MAX_REDIRECTS   = 5
  SESSION_TIMEOUT = 10.seconds

  @pin : String = ""
  @rejected_pin : String? = nil
  @content_port : Int32 = 6869
  @content_base_url : String? = nil
  @download_timeout : Time::Span = 60.seconds
  @server : ContentServer? = nil
  @session_lock : Mutex = Mutex.new

  def on_load
    on_update
  end

  def on_update
    @pin = setting?(String, :pin) || ""
    @rejected_pin = nil unless @rejected_pin == @pin
    @content_base_url = setting?(String, :content_base_url).presence
    @download_timeout = (setting?(Int32, :download_timeout) || 60).seconds

    port = setting?(Int32, :content_port) || 6869
    return if @server && port == @content_port

    @server.try { ContentServer.release(@content_port) }
    @server = nil
    @content_port = port
    start_content_server
  end

  def on_unload
    @server.try { ContentServer.release(@content_port) }
    @server = nil
  end

  # Downloads the picture at *url*, following redirects, and shows it on the display
  def show_image_url(url : String) : Delivery
    show download_image(url)
  end

  # Shows a base64 encoded picture. Accepts a `data:` URI or plain base64.
  def show_image_base64(image : String) : Delivery
    show decode_image(image)
  end

  # E-paper displays have a single output, so *output_index* is ignored
  def set_background_image(url : String, output_index : Int32? = nil) : Nil
    show_image_url(url)
    nil
  end

  # Reads the display's name, serial number, firmware and battery
  def query_status : DeviceStatus
    status = with_session(display_host) do |session|
      DeviceStatus.new(
        name: session.text?(Command::DeviceName),
        serial_number: session.text?(Command::SerialNumber),
        firmware: session.text?(Command::SoftwareVersion),
        battery: session.battery?,
      )
    end

    self[:device_name] = status.name
    self[:serial_number] = status.serial_number
    self[:firmware] = status.firmware
    self[:battery_level] = status.battery.try(&.percent)
    self[:charging] = status.battery.try(&.charging?)
    status
  end

  protected def show(image : Bytes) : Delivery
    format = ImageFormat.detect(image)
    raise ArgumentError.new("unsupported picture format, expected JPEG, PNG or BMP") unless format

    host = display_host
    id = UUID.random.to_s.upcase
    base = content_base_url(host)
    manifest_url = "#{base}/c/#{id}/content.json"
    command_data = Samsung::Epaper.content_download_data(manifest_url)
    manifest = Manifest.build(id, "#{base}/c/#{id}/image.#{format.extension}", image.size, format, "PlaceOS")

    item = server.add(id, manifest.serialise, image, format)
    begin
      with_session(host, &.command(Command::ContentDownload, command_data))
      unless item.wait_for_download(@download_timeout)
        missing = item.manifest_fetched? ? "the picture" : "the manifest"
        raise "the display accepted the request but did not download #{missing} from #{manifest_url}"
      end
    rescue error
      server.remove(id)
      raise error
    end

    logger.debug { "display downloaded #{image.size} byte #{format} #{id}" }
    delivery = Delivery.new(id, format, image.size, manifest_url, Time.utc.to_unix)
    self[:last_delivery] = delivery
    delivery
  end

  protected def with_session(host : String, & : Session -> T) : T forall T
    pin = @pin
    raise "set the pin setting to the PIN shown on the display" if pin.empty?
    raise "the display rejected the configured PIN, update the pin setting" if @rejected_pin == pin

    @session_lock.synchronize do
      session = Session.new(host, display_port, SESSION_TIMEOUT)
      begin
        session.open(pin)
        result = yield session
        set_connected_state(true)
        result
      rescue error : MDCError
        @rejected_pin = pin if error.code.incorrect_pin?
        set_connected_state(false) if error.code.unreachable?
        raise error
      ensure
        session.close
      end
    end
  end

  protected def display_host : String
    config.ip.presence || raise "the display's IP address is not configured"
  end

  protected def display_port : Int32
    setting?(Int32, :mdc_port) || config.port || 1515
  end

  protected def server : ContentServer
    @server || start_content_server || raise "the content server could not listen on port #{@content_port}"
  end

  protected def start_content_server : ContentServer?
    server = ContentServer.acquire(@content_port)
    @server = server
    self[:content_port] = server.port
    server
  rescue error
    logger.error(exception: error) { "starting the content server on port #{@content_port}" }
    self[:content_port] = nil
    nil
  end

  protected def content_base_url(host : String) : String
    if base = @content_base_url
      return base.rchop('/')
    end

    address = local_address_for(host)
    address = "[#{address}]" if address.includes?(':')
    "http://#{address}:#{server.port}"
  end

  # The address this host uses to reach *host*
  protected def local_address_for(host : String) : String
    addrinfo = Socket::Addrinfo.udp(host, display_port).first
    socket = UDPSocket.new(addrinfo.family)
    begin
      # connecting a UDP socket sends nothing, it only selects the route
      socket.connect(addrinfo)
      socket.local_address.address
    ensure
      socket.close
    end
  end

  protected def download_image(url : String) : Bytes
    uri = URI.parse(url)

    (MAX_REDIRECTS + 1).times do
      unless uri.scheme.in?("http", "https") && uri.host.presence
        raise ArgumentError.new("expected an http or https URL: #{uri}")
      end

      location = nil
      client = HTTP::Client.new(uri, tls: uri.scheme == "https" ? OpenSSL::SSL::Context::Client.insecure : nil)
      begin
        client.connect_timeout = 10.seconds
        client.read_timeout = 30.seconds
        client.get(uri.request_target) do |response|
          if response.status.redirection?
            location = response.headers["Location"]? || raise "redirect from #{uri} has no Location header"
          elsif response.success?
            return read_image(response.body_io)
          else
            raise "downloading #{uri} failed with HTTP #{response.status_code}"
          end
        end
      ensure
        client.close
      end

      uri = uri.resolve(location.as(String))
    end

    raise "too many redirects downloading #{url}"
  end

  protected def read_image(io : IO) : Bytes
    buffer = IO::Memory.new
    copied = IO.copy(io, buffer, MAX_IMAGE_BYTES + 1)
    raise ArgumentError.new("the picture is larger than #{MAX_IMAGE_BYTES // 1024 // 1024} MiB") if copied > MAX_IMAGE_BYTES
    buffer.to_slice
  end

  protected def decode_image(image : String) : Bytes
    data = image.strip
    if data.starts_with?("data:")
      comma = data.index(',') || raise ArgumentError.new("the data URI has no data")
      data = data[(comma + 1)..]
    end
    data = data.gsub(/\s+/, "")

    raise ArgumentError.new("the picture is larger than #{MAX_IMAGE_BYTES // 1024 // 1024} MiB") if data.bytesize // 4 * 3 > MAX_IMAGE_BYTES
    Base64.decode(data)
  rescue error : Base64::Error
    raise ArgumentError.new("the picture is not valid base64: #{error.message}")
  end

  # One authenticated MDC session. The display accepts a single session at a time.
  class Session
    BANNER        = "MDCSTART<<TLS>>"
    AUTH_PASS     = "MDCAUTH<<PASS>>"
    AUTH_FAILURES = {
      "MDCAUTH<<FAIL:0x01>>" => {MDCError::Code::IncorrectPin, "the display rejected the PIN"},
      "MDCAUTH<<FAIL:0x02>>" => {MDCError::Code::Blocked, "the display is refusing PIN attempts after too many failures"},
    }

    @tcp : TCPSocket? = nil
    @io : IO? = nil

    def initialize(@host : String, @port : Int32, @timeout : Time::Span)
    end

    def open(pin : String) : Nil
      tcp = TCPSocket.new(@host, @port, connect_timeout: @timeout)
      @tcp = tcp
      tcp.read_timeout = @timeout
      tcp.write_timeout = @timeout

      banner = read_text(tcp)
      raise MDCError.new(:protocol, "the display is not using the secured MDC protocol: #{banner.inspect}") unless banner == BANNER

      # the display presents a self-signed certificate
      tls = OpenSSL::SSL::Socket::Client.new(tcp, context: OpenSSL::SSL::Context::Client.insecure, sync_close: true)
      @io = tls
      tls.write pin.to_slice
      tls.flush

      reply = read_text(tls)
      return if reply == AUTH_PASS

      code, message = AUTH_FAILURES[reply]? || {MDCError::Code::Protocol, "unexpected reply to the PIN: #{reply.inspect}"}
      raise MDCError.new(code, message)
    rescue error : Socket::ConnectError | IO::TimeoutError
      raise MDCError.new(:unreachable, "no answer from the display at #{@host}:#{@port}: #{error.message}")
    rescue error : OpenSSL::SSL::Error
      raise MDCError.new(:protocol, "TLS negotiation with the display failed: #{error.message}")
    end

    # Sends a command and returns the payload of the display's response
    def command(command : Command, data : Bytes = Bytes.empty) : Bytes
      io = @io || raise MDCError.new(:protocol, "the MDC session is not open")
      io.write Samsung::Epaper.request(command, data)
      io.flush

      response = Response.parse(read_frame(io))
      unless response.command == command.value
        raise MDCError.new(:protocol, "expected a response to #{command} but got 0x#{response.command.to_s(16)}")
      end
      raise MDCError.new(:rejected, "the display rejected #{command}") unless response.ack?
      response.payload
    rescue IO::TimeoutError
      raise MDCError.new(:unreachable, "the display did not answer #{command}")
    end

    # Reads a text value, or nil when the display does not support it
    def text?(command : Command) : String?
      String.new(command(command)).delete('\u0000').strip
    rescue error : MDCError
      raise error unless error.code.rejected?
      nil
    end

    # Reads the battery state, or nil when the display does not report it
    def battery? : Battery?
      Battery.parse(command(Command::Status, Bytes[STATUS_BATTERY]))
    rescue error : MDCError
      raise error unless error.code.rejected?
      nil
    end

    def close : Nil
      @io.try(&.close) rescue nil
      @tcp.try(&.close) rescue nil
    end

    # Reads a plain text message, which ends with ">>"
    private def read_text(io : IO) : String
      buffer = IO::Memory.new
      until buffer.size >= 64 || buffer.to_s.ends_with?(">>")
        byte = io.read_byte || raise MDCError.new(:protocol, "the display closed the connection")
        buffer.write_byte byte
      end
      buffer.to_s
    end

    private def read_frame(io : IO) : Bytes
      until (io.read_byte || raise MDCError.new(:protocol, "the display closed the connection")) == HEADER
      end

      head = Bytes.new(3)
      io.read_fully(head)
      rest = Bytes.new(head[2].to_i + 1)
      io.read_fully(rest)

      frame = IO::Memory.new
      frame.write_byte HEADER
      frame.write head
      frame.write rest
      frame.to_slice
    rescue IO::EOFError
      raise MDCError.new(:protocol, "the display closed the connection")
    end
  end

  # Serves manifests and pictures to displays. Modules in one driver process share one
  # server per port.
  class ContentServer
    LIFETIME = 10.minutes
    PATH     = /\A\/c\/([0-9A-F-]{36})\/(content\.json|image\.(?:jpg|png|bmp))\z/

    class Item
      getter manifest : String
      getter image : Bytes
      getter format : ImageFormat
      getter created_at : Time::Span
      getter? manifest_fetched : Bool = false

      @downloaded : Channel(Nil) = Channel(Nil).new

      def initialize(@manifest, @image, @format)
        @created_at = Time.monotonic
      end

      def manifest_fetched! : Nil
        @manifest_fetched = true
      end

      def downloaded! : Nil
        @downloaded.close unless @downloaded.closed?
      end

      # Waits for the picture to be downloaded. Returns false on timeout.
      def wait_for_download(timeout : Time::Span) : Bool
        select
        when @downloaded.receive?
          true
        when timeout(timeout)
          false
        end
      end
    end

    @@servers = {} of Int32 => ContentServer
    @@lock = Mutex.new

    def self.acquire(port : Int32) : ContentServer
      @@lock.synchronize do
        server = @@servers[port] ||= new(port)
        server.users += 1
        server
      end
    end

    def self.release(port : Int32) : Nil
      @@lock.synchronize do
        server = @@servers[port]?
        next unless server

        server.users -= 1
        if server.users <= 0
          @@servers.delete(port)
          server.close
        end
      end
    end

    property users : Int32 = 0
    getter port : Int32

    @items : Hash(String, Item) = {} of String => Item
    @lock : Mutex = Mutex.new

    def initialize(requested_port : Int32)
      @server = HTTP::Server.new { |context| handle(context) }
      @port = @server.bind_tcp("0.0.0.0", requested_port).port
      spawn(name: "emdx-content-server") { @server.listen }
    end

    def add(id : String, manifest : String, image : Bytes, format : ImageFormat) : Item
      item = Item.new(manifest, image, format)
      @lock.synchronize do
        expired = Time.monotonic - LIFETIME
        @items.reject! { |_id, existing| existing.created_at < expired }
        @items[id] = item
      end
      item
    end

    def remove(id : String) : Nil
      @lock.synchronize { @items.delete(id) }
    end

    def close : Nil
      @server.close
    end

    private def handle(context : HTTP::Server::Context) : Nil
      request = context.request
      response = context.response
      match = PATH.match(request.path) if request.method == "GET"
      item = match ? @lock.synchronize { @items[match[1]]? } : nil

      unless match && item
        response.status = :not_found
        return
      end

      if match[2] == "content.json"
        item.manifest_fetched!
        response.content_type = "application/json"
        response.print item.manifest
      else
        response.content_type = item.format.mime_type
        response.content_length = item.image.size
        response.write item.image
        response.flush
        item.downloaded!
      end
    end
  end
end
