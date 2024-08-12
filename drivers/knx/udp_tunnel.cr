require "placeos-driver"
require "socket"
require "./disptach_model"
require "knx/tunnel_client"

class KNX::TunnelDriver < PlaceOS::Driver
  generic_name :KNX
  descriptive_name "KNX Connector"
  description %(makes KNX data available to other drivers in PlaceOS)

  # Hookup dispatch to accept incoming packets from the KNX interface
  uri_base "ws://dispatch/api/dispatch/v1/udp_dispatch?port=3671&accept=192.168.0.1"

  default_settings({
    dispatcher_key:  "secret",
    dispatcher_ip:   "192.168.0.1",
    dispatcher_port: 3671,
    broadcast:       true,
    repeat:          false,
    hop_count:       6,
  })

  def websocket_headers
    dispatcher_key = setting?(String, :dispatcher_key)
    HTTP::Headers{
      "Authorization" => "Bearer #{dispatcher_key}",
      "X-Module-ID"   => module_id,
    }
  end

  def on_load
    queue.wait = false
    on_update
  end

  protected getter! udp_socket : UDPSocket
  protected getter! knx_client : KNX::TunnelClient
  protected getter! knx_control : Socket::IPAddress
  protected getter! knx_interface : Socket::IPAddress

  getter? websocket_connected : Bool = false
  getter? knx_client_connected : Bool = false

  @mutex : Mutex = Mutex.new

  def on_update
    ip = setting(String, :dispatcher_ip)
    port = setting(UInt16, :dispatcher_port)
    params = URI.parse(config.uri.as(String)).query_params

    @knx_control = control_ip = Socket::IPAddress.new(ip, port)
    interface_ip = params["accept"].strip.split(',').first
    @knx_interface = interface_ip = Socket::IPAddress.new(interface_ip, params["port"].to_i)

    broadcast = setting?(Bool, :broadcast) || false
    repeat = setting?(Bool, :repeat) || false
    hop_count = setting?(UInt8, :hop_count) || 6_u8
    source = setting?(String, :source_address) || "0.0.0"

    spawn { @mutex.synchronize { establish_comms(control_ip, interface_ip, broadcast, repeat, hop_count, source) } }
  end

  protected def establish_comms(control_ip, interface_ip, broadcast, repeat, hop_count, source)
    # cleanup old connections
    if old_client = @knx_client
      old_client.shutdown! rescue nil
      @knx_client = nil
    end

    if old_socket = @udp_socket
      @udp_socket = nil
      old_socket.close
    end

    # establish a UDP port for sending data to the interface
    logger.info { "connecting to #{interface_ip}" }
    @udp_socket = udp_socket = UDPSocket.new
    udp_socket.connect interface_ip.address, interface_ip.port
    udp_socket.write_timeout = 200.milliseconds

    # client handles the UDP virtual connection state
    knx = ::KNX.new(broadcast: broadcast, no_repeat: !repeat, hop_count: hop_count, source: source)
    @knx_client = client = KNX::TunnelClient.new(control_ip, knx: knx)
    client.on_state_change(&->knx_connected_state(Bool, KNX::ConnectionError))
    client.on_transmit(&->knx_transmit_request(Bytes))
    client.on_message(&->knx_new_message(KNX::CEMI))

    spawn { client.connect } if @websocket_connected
  end

  # this is called when we're connected to dispatcher and can receive messages
  def connected
    logger.debug { "Websocket connected!" }
    @websocket_connected = true

    schedule.clear
    client = knx_client
    schedule.every(1.minute) do
      logger.debug { "Polling KNX connection" }
      client.connected? ? client.query_state : client.connect
    end

    spawn { client.connected? ? client.query_state : client.connect }
  end

  def disconnected
    logger.debug { "Websocket disconnected!" }
    @websocket_connected = false
    schedule.clear
  end

  # =========
  # Callbacks
  # =========

  protected def knx_connected_state(connected : Bool, error : KNX::ConnectionError)
    logger.debug { "<KNX> connection state: #{connected} (#{error})" }
    @knx_client_connected = connected
    self[:connected] = connected

    # attempt to reconnect
    if !connected && websocket_connected?
      knx_client.connect
    end
  end

  protected def knx_transmit_request(payload : Bytes)
    logger.debug do
      io = IO::Memory.new(payload)
      header = io.read_bytes(KNX::Header)
      "<KNX> transmitting #{header.request_type}: #{payload.hexstring}"
    end
    udp_socket.write payload
  end

  protected def knx_new_message(cemi : KNX::CEMI)
    logger.debug { "<KNX> received: #{cemi.inspect}" }
    self[cemi.destination_address.to_s] = cemi.data.hexstring
  end

  # =========
  # Interface
  # =========

  def action(address : String, data : Bool | Int32 | String) : Nil
    knx_client.action(address, data)
  end

  # split out float to prevent type confusion parsing in JSON
  def action_float(address : String, data : Float32) : Nil
    knx_client.action(address, data)
  end

  def status(address : String) : Nil
    knx_client.status(address)
  end

  def received(data, task)
    protocol = IO::Memory.new(data).read_bytes(DispatchProtocol)
    logger.debug { "received message: #{protocol.message} from #{protocol.ip_address}" }

    return unless protocol.message.received?

    logger.debug { "received payload: 0x#{protocol.data.hexstring}" }
    logger.debug do
      begin
        io = IO::Memory.new(protocol.data)
        header = io.read_bytes(KNX::Header)
        "received #{header.request_type} message"
      rescue error
        "received bad KNX message"
      end
    end
    knx_client.process(protocol.data)

    task.try &.success
  end
end
