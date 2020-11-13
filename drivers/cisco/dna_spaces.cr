module Cisco; end

require "s2_cells"
require "placeos-driver/interface/locatable"

class Cisco::DNASpaces < PlaceOS::Driver
  include Interface::Locatable

  # Discovery Information
  descriptive_name "Cisco DNA Spaces"
  generic_name :DNA_Spaces
  uri_base "https://partners.dnaspaces.io"

  default_settings({
    dna_spaces_api_key: "X-API-KEY",
    tenant_id:          "sfdsfsdgg",
    location_id:        "location-d827508f",
  })

  def on_load
    on_update
  end

  @api_key : String = ""

  def on_update
    @api_key = setting(String, :dna_spaces_api_key)
  end

  def get_location_info(location_id : String)
    Events.from_json(location_id).payload
  end

  def stream_events
    route = "/api/partners/v1/firehose/events"
    headers = {
      "X-API-KEY" => @api_key,
    }
  end

  private def process_events(channel, client)
    loop do
      select
      when data = channel.receive
        logger.debug { "received push #{data}" }
      # TODO:: update state
      when timeout(20.seconds)
        logger.debug { "no events received for 20 seconds, expected heartbeat at 15 seconds" }
        channel.close
        client.close
        break
      end
    end
  end

  def stream_events
    client = HTTP::Client.new URI.parse(config.uri.not_nil!)
    client.get("/api/partners/v1/firehose/events", HTTP::Headers{
      "X-API-KEY" => @api_key,
    }) do |response|
      if !response.success?
        logger.warn { "failed to connect to firehose api #{response.status_code}" }
        raise "failed to connect to firehose api #{response.status_code}"
      end

      channel = Channel(String).new
      spawn { process_events(channel, client) }

      begin
        loop do
          if response.body_io.closed?
            channel.close
            break
          end
          if data = response.body_io.gets
            channel.send data
          else
            channel.close
            break
          end
        end
      rescue IO::Error
        channel.close
      end
    end
  end

  def locate_user(email : String? = nil, username : String? = nil)
    logger.debug { "searching for #{email}, #{username}" }
    [] of JSON::Any
  end

  # Will return an array of MAC address strings
  # lowercase with no seperation characters abcdeffd1234 etc
  def macs_assigned_to(email : String? = nil, username : String? = nil)
    logger.debug { "listing MAC addresses assigned to #{email}, #{username}" }
    [] of String
  end

  # Will return `nil` or `{"location": "wireless", "assigned_to": "bob123", "mac_address": "abcd"}`
  def check_ownership_of(mac_address : String)
    logger.debug { "searching for owner of #{mac_address}" }
    nil
  end

  # Will return an array of devices and their x, y coordinates
  def device_locations(zone_id : String, location : String? = nil)
    logger.debug { "searching devices in zone #{zone_id}" }
    [] of JSON::Any
  end
end

require "./dna_spaces/events"
