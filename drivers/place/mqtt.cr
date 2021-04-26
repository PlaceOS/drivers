require "./mqtt_transport_adaptor"

class Place::MQTT < PlaceOS::Driver
  descriptive_name "Generic MQTT"
  generic_name :GenericMQTT

  tcp_port 1883
  description %(makes MQTT data available to other drivers in PlaceOS, for use with String payloads)

  default_settings({
    username:      "user",
    password:      "pass",
    keep_alive:    60,
    client_id:     "placeos",
    subscriptions: ["root/#"],
  })

  @keep_alive : Int32 = 60
  @username : String? = nil
  @password : String? = nil
  @client_id : String = "placeos"

  @mqtt : ::MQTT::V3::Client? = nil
  @subs : Array(String) = [] of String
  @transport : Place::TransportAdaptor? = nil
  @sub_proc : Proc(String, Bytes, Nil) = Proc(String, Bytes, Nil).new { |_key, _payload| nil }

  def on_load
    @sub_proc = Proc(String, Bytes, Nil).new { |key, payload| on_message(key, payload) }
    on_update
  end

  def on_update
    @username = setting?(String, :username)
    @password = setting?(String, :password)
    @keep_alive = setting?(Int32, :keep_alive) || 60
    @client_id = setting?(String, :client_id) || ::MQTT.generate_client_id("placeos_")

    existing = @subs
    @subs = setting?(Array(String), :subscriptions) || [] of String

    if client = @mqtt
      unsub = existing - @subs
      newsub = @subs - existing

      unsub.each { |sub| client.unsubscribe(sub) }
      newsub.each { |sub| client.subscribe(sub, &@sub_proc) }
    end
  end

  def connected
    transp = Place::TransportAdaptor.new(transport, queue)
    client = ::MQTT::V3::Client.new(transp)
    @transport = transp
    @mqtt = client

    client.connect(@username, @password, @keep_alive, @client_id)
    @subs.each { |sub| client.subscribe(sub, &@sub_proc) }
  end

  def disconnected
    @transport = nil
    @mqtt = nil
  end

  protected def on_message(key : String, playload : Bytes) : Nil
    self[key] = String.new(playload)
  end

  def publish(key : String, payload : String) : Nil
    @mqtt.not_nil!.publish(key, payload)
    nil
  end

  def received(data, task)
    logger.debug { "received: 0x#{data.hexstring}" }
    @transport.try &.process(data)
    task.try &.success
  end
end
