require "mqtt"

class Place::TransportAdaptor < MQTT::Transport
  def initialize(@driver, @queue)
    super()
  end

  @driver : PlaceOS::Driver::Transport
  @queue : PlaceOS::Driver::Queue

  def close! : Nil
    @driver.disconnect
  end

  def closed? : Bool
    !@queue.online
  end

  def send(message) : Nil
    @driver.send(message.to_slice)
  end

  def process(data : Bytes)
    @tokenizer.extract(data).each do |bytes|
      spawn { @on_message.try &.call(bytes) }
    end
  end
end
