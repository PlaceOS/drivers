require "json"
require "placeos-driver"
require "placeos-driver/interface/locatable"

class KontaktIO::MacAddressMappings < PlaceOS::Driver
  # Discovery Information
  descriptive_name "Kontakt IO Device MAC to Username Mapper"
  generic_name :KontaktMacMappings

  default_settings({
    kio_api_key: "Sign in to Kio Cloud > select Users > select Security > copy the Server API Key",
  })

  def on_load
    on_update
    schedule.every(1.hour) { map_devices }
    schedule.in(10.seconds) { map_devices }
  end

  @api_key : String = ""

  def on_update
    @api_key = setting(String, :kio_api_key)
  end

  class SearchMeta
    include JSON::Serializable

    @[JSON::Field(key: "nextResults")]
    getter next_results : String
  end

  class DeviceDetails
    include JSON::Serializable

    getter alias : String?
    getter mac : String
  end

  def map_devices
    request = "https://api.kontakt.io/device?maxResult=500&deviceType=BEACON"

    locatable = system.implementing(Interface::Locatable)

    while request.presence
      response = HTTP::Client.get(request, headers: HTTP::Headers{
        "Api-Key"      => @api_key,
        "Content-Type" => "application/json",
        "Accept"       => "application/vnd.com.kontakt+json;version=10",
      })

      logger.debug { "request returned:\n#{response.body}" }
      case response.status_code
      when 303
        # TODO:: follow the redirect
      when 401
        logger.warn { "The API Key is invalid or disabled" }
      when 403
        logger.warn { "User who created the API no longer has access to the Kio Cloud account or their user role doesn't allow access to the endpoint. Device error if the endpoint is not available for the device model." }
      end

      raise "request #{request} failed with status: #{response.status_code}" unless response.success?

      result = NamedTuple(devices: Array(DeviceDetails), searchMeta: SearchMeta).from_json(response.body)
      meta = result[:searchMeta]
      request = meta.next_results

      result[:devices].each do |device|
        next unless device.alias.presence
        locatable.mac_address_mappings(device.alias, {device.mac}, "").get
      end
    end
  end
end
