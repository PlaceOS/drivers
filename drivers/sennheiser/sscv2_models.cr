require "json"
require "http/client"
require "uri"

module Sennheiser::SSCv2
  # SSE Event types
  enum EventType
    Open
    Message
    Close

    def self.from_string(value : String)
      case value.downcase
      when "open"
        Open
      when "message", ""
        Message
      when "close"
        Close
      else
        Message
      end
    end
  end

  # SSE Event structure
  struct SSEEvent
    include JSON::Serializable

    getter event_type : EventType
    getter data : JSON::Any

    def initialize(@event_type : EventType, @data : JSON::Any)
    end

    def self.parse_line(line : String) : SSEEvent?
      return nil if line.blank?

      if line.starts_with?("event:")
        event_type = EventType.from_string(line[6..].strip)
        return SSEEvent.new(event_type, JSON::Any.new({} of String => JSON::Any))
      elsif line.starts_with?("data:")
        data_str = line[5..].strip
        begin
          data = JSON.parse(data_str)
          return SSEEvent.new(EventType::Message, data)
        rescue JSON::ParseException
          return nil
        end
      end

      nil
    end
  end

  # Subscription status response
  struct SubscriptionStatus
    include JSON::Serializable

    getter path : String
    getter sessionUUID : String

    def initialize(@path : String, @sessionUUID : String)
    end
  end

  # Error response structure
  struct ErrorResponse
    include JSON::Serializable

    getter path : String
    getter error : Int32

    def initialize(@path : String, @error : Int32)
    end
  end

  # Device site information
  struct DeviceSite
    include JSON::Serializable

    getter name : String
    getter location : String
    getter site : String

    def initialize(@name : String, @location : String, @site : String)
    end
  end

  # SSE Subscription processor
  class SubscriptionProcessor
    getter session_uuid : String?
    getter base_url : String
    getter username : String
    getter password : String
    getter subscribed_resources : Array(String)
    getter running : Bool = false

    private getter client : HTTP::Client?
    private getter callback : Proc(String, JSON::Any, Nil)?
    private getter error_callback : Proc(String, Nil)?
    private getter reconnect_attempts : Int32 = 0
    private getter max_reconnect_attempts : Int32 = 10
    private getter base_reconnect_delay : Time::Span = 1.second
    private getter max_reconnect_delay : Time::Span = 5.seconds

    def initialize(@base_url : String, @username : String, @password : String)
      @subscribed_resources = Array(String).new
      @running = false
    end

    def on_data(&block : String, JSON::Any -> Nil)
      @callback = block
    end

    def on_error(&block : String -> Nil)
      @error_callback = block
    end

    def start
      return if @running
      @running = true
      @reconnect_attempts = 0
      connect
    end

    def stop
      @running = false
      @client.try(&.close)
      @client = nil
      @session_uuid = nil
    end

    def subscribe_to_resources(resources : Array(String))
      return unless session_uuid = @session_uuid
      return if resources.empty?

      uri = URI.parse(@base_url)
      client = HTTP::Client.new(uri.host.not_nil!, uri.port)
      client.basic_auth(@username, @password)

      begin
        response = client.put("/api/ssc/state/subscriptions/#{session_uuid}",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: resources.to_json)

        if response.success?
          @subscribed_resources.clear
          @subscribed_resources.concat(resources)
        else
          @error_callback.try(&.call("Failed to subscribe to resources: #{response.status_code}"))
        end
      rescue ex
        @error_callback.try(&.call("Error subscribing to resources: #{ex.message}"))
      ensure
        client.close
      end
    end

    def add_resources(resources : Array(String))
      return unless session_uuid = @session_uuid
      return if resources.empty?

      uri = URI.parse(@base_url)
      client = HTTP::Client.new(uri.host.not_nil!, uri.port)
      client.basic_auth(@username, @password)

      begin
        response = client.put("/api/ssc/state/subscriptions/#{session_uuid}/add",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: resources.to_json)

        if response.success?
          @subscribed_resources.concat(resources)
        else
          @error_callback.try(&.call("Failed to add resources: #{response.status_code}"))
        end
      rescue ex
        @error_callback.try(&.call("Error adding resources: #{ex.message}"))
      ensure
        client.close
      end
    end

    def remove_resources(resources : Array(String))
      return unless session_uuid = @session_uuid
      return if resources.empty?

      uri = URI.parse(@base_url)
      client = HTTP::Client.new(uri.host.not_nil!, uri.port)
      client.basic_auth(@username, @password)

      begin
        response = client.put("/api/ssc/state/subscriptions/#{session_uuid}/remove",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: resources.to_json)

        if response.success?
          resources.each { |resource| @subscribed_resources.delete(resource) }
        else
          @error_callback.try(&.call("Failed to remove resources: #{response.status_code}"))
        end
      rescue ex
        @error_callback.try(&.call("Error removing resources: #{ex.message}"))
      ensure
        client.close
      end
    end

    private def connect
      return unless @running

      uri = URI.parse(@base_url)
      client = HTTP::Client.new(uri.host.not_nil!, uri.port)
      client.basic_auth(@username, @password)
      @client = client

      begin
        client.exec("GET", "/api/ssc/state/subscriptions") do |response|
          if response.success?
            @reconnect_attempts = 0

            # Extract session UUID from Content-Location header
            if location = response.headers["Content-Location"]?
              @session_uuid = location.split("/").last
            end

            # Process the SSE stream
            process_sse_stream(response.body_io)
          else
            handle_connection_error("HTTP error: #{response.status_code}")
          end
        end
      rescue ex
        handle_connection_error("Connection error: #{ex.message}")
      end
    end

    private def process_sse_stream(io : IO)
      buffer = ""
      current_event_type = EventType::Message

      while @running
        begin
          line = io.gets
          break if line.nil?

          line = line.strip

          if line.empty?
            # End of event, process if we have data
            if !buffer.empty?
              process_event(current_event_type, buffer)
              buffer = ""
              current_event_type = EventType::Message
            end
          elsif line.starts_with?("event:")
            current_event_type = EventType.from_string(line[6..].strip)
          elsif line.starts_with?("data:")
            data_line = line[5..].strip
            buffer += data_line
          end
        rescue ex
          @error_callback.try(&.call("Error reading SSE stream: #{ex.message}"))
          break
        end
      end

      # Connection ended, schedule reconnect if still running
      if @running
        handle_connection_error("SSE stream ended")
      end
    end

    private def process_event(event_type : EventType, data : String)
      case event_type
      when .open?
        begin
          parsed_data = JSON.parse(data)
          if session_uuid = parsed_data["sessionUUID"]?.try(&.as_s)
            @session_uuid = session_uuid
          end
        rescue JSON::ParseException
          @error_callback.try(&.call("Failed to parse open event data"))
        end
      when .message?
        begin
          parsed_data = JSON.parse(data)
          # Process each resource update in the data
          parsed_data.as_h.each do |resource_path, resource_data|
            @callback.try(&.call(resource_path, resource_data))
          end
        rescue JSON::ParseException
          @error_callback.try(&.call("Failed to parse message event data"))
        end
      when .close?
        @running = false
        @session_uuid = nil
      end
    end

    private def handle_connection_error(error : String)
      @error_callback.try(&.call(error))

      return unless @running
      return if @reconnect_attempts >= @max_reconnect_attempts

      @reconnect_attempts += 1
      delay = calculate_reconnect_delay

      spawn do
        sleep delay
        connect if @running
      end
    end

    private def calculate_reconnect_delay : Time::Span
      # Exponential backoff with jitter
      delay_seconds = [@base_reconnect_delay.seconds * (2 ** (@reconnect_attempts - 1)), @max_reconnect_delay.seconds].min
      jitter = Random.rand(0.1..0.3) * delay_seconds
      (delay_seconds + jitter).seconds
    end
  end
end
