module Cisco
  module Webex
    class Session
      Log = ::Log.for(self)

      property base_url : String = Constants::DEFAULT_BASE_URL
      property single_request_timeout : Int32 = Constants::DEFAULT_SINGLE_REQUEST_TIMEOUT
      property user_agent : String = ["Tepha", Constants::VERSION].join(" ")
      property wait_on_rate_limit : Bool = Constants::DEFAULT_WAIT_ON_RATE_LIMIT

      private property client : Halite::Client = Halite::Client.new

      def initialize(@access_token : String)
      end

      def request(method : String, url : String, **kwargs) : Halite::Response
        # Abstract base method for making requests to the Webex Teams APIs.
        # This base method:
        #     * Expands the API endpoint URL to an absolute URL
        #     * Makes the actual HTTP request to the API endpoint
        #     * Provides support for Webex Teams rate-limiting
        #     * Inspects response codes and raises exceptions as appropriate

        absolute_url = URI.parse(base_url).resolve(url).to_s

        @client.headers({"Authorization" => ["Bearer", @access_token].join(" ")})
        @client.headers({"Content-Type" => "application/json;charset=utf-8"})
        @client.timeout single_request_timeout

        loop do
          case method
          when "GET"
            response = @client.get absolute_url, **kwargs
          when "POST"
            response = @client.post absolute_url, **kwargs
          when "PUT"
            response = @client.put absolute_url, **kwargs
          when "DELETE"
            response = @client.delete absolute_url, **kwargs
          else
            raise Exceptions::Method.new("The request-method type is invalid.")
          end

          begin
            status_code = StatusCode.new(response.status_code)
            raise Exceptions::RateLimit.new(status_code.message) if response.status_code == 429
            raise Exceptions::StatusCode.new(status_code.message) if !status_code.valid?

            return response
          rescue e : Exceptions::StatusCode
            Log.error(exception: e) { }
          rescue e : Exceptions::RateLimit
            Log.error(exception: e) { }

            retry_after = (response.headers["Retry-After"]? || "15").to_i * 1000
            sleep(retry_after)
          end
        end
      end

      def get(url : String, **kwargs) : Halite::Response
        # Sends a GET request.
        request("GET", url, **kwargs)
      end

      def post(url : String, **kwargs) : Halite::Response
        # Sends a POST request.
        request("POST", url, **kwargs)
      end

      def put(url : String, **kwargs) : Halite::Response
        # Sends a PUT request.
        request("PUT", url, **kwargs)
      end

      def delete(url : String, **kwargs) : Halite::Response
        # Sends a DELETE request.
        request("DELETE", url, **kwargs)
      end
    end
  end
end
