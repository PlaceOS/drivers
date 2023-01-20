require "placeos-driver"
require "halite"

module Kappture
  class ProductSignageText < PlaceOS::Driver
    # Discovery Information
    descriptive_name "Kappture Product Signage Text"
    generic_name :Kappture
    uri_base "https://api.kappture.co.uk/data/api"

    default_settings({
      api_key: "ABCDEF123456",
      debug:   false,
    })

    @api_key : String = ""
    @debug : Bool = false

    def on_load
      on_update
    end

    def on_update
      @api_key = setting(String, :api_key)
      @debug = setting?(Bool, :debug) || false
    end

    def get_product_signage_text(outlet_id : Int32, session_id : Int32)
      url = [config.uri.not_nil!.to_s, "/ProductSignageText"].join

      response = Halite.get(url, headers: {"KAPPTURE_API_KEY" => @api_key}, params: {"outletId" => outlet_id, "sessionId" => session_id})

      logger.debug { "Response: #{response.status_code}, #{response.body}" } if @debug

      raise "Returned an unsuccessfull status code from the server" unless response.success?

      JSON.parse(response.body)
    end
  end
end
