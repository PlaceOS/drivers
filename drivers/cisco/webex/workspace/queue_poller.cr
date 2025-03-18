require "uri"
require "json"
require "log"
require "connect-proxy"
require "./jws"
require "./messages"

module WebxWorkspace
  class QueuePoller
    alias HeaderTokens = Proc(HTTP::Headers)
    Log = ::Log.for(self)
    getter url : URI
    getter token_headers : HeaderTokens
    getter decoder : JWTDecoder
    getter consumer : (Array(Message)) ->
    @running : Atomic(Bool)
    @client : ConnectProxy::HTTPClient

    def initialize(@url, @decoder, proxy_config : WebxWorkspace::ProxyConfig?, @token_headers, @consumer)
      @running = Atomic(Bool).new(false)
      @client = WebxWorkspace.new_client(@url, proxy_config)
    end

    def start
      return if @running.get
      @running.set(true)
      spawn do
        loop do
          break unless @running.get
          headers = token_headers.call
          response = @client.get(url.request_target, headers: headers)
          raise "failed to patch integration endpoint, code #{response.status_code}, body #{response.body}" unless response.success?
          messages = Array(Message).from_json(response.body, "messages")
          consume(messages)
        rescue ex : Exception
          Log.error(exception: ex) { "encountered error in polling, sleeping 10 seconds" }
          sleep(10.seconds)
        end
      end
    end

    def stop
      @running.set(false)
    end

    private def consume(messages : Array(Message))
      begin
        consumer.call(messages)
      rescue ex : Exception
        Log.error(exception: ex) { "unexpected exception raised in message consumer" }
      end
    end
  end
end
