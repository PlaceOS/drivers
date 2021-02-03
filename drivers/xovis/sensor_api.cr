module Xovis; end

require "xml"

class Xovis::SensorAPI < PlaceOS::Driver
  # Discovery Information
  generic_name :XovisSensor
  descriptive_name "Xovis Flow Sensor"

  uri_base "https://192.168.0.1"

  default_settings({
    basic_auth: {
      username: "account",
      password: "password!",
    },
  })

  def on_load
    on_update
  end

  def on_update
  end

  # Alternative to using basic auth, but here really only for testing with postman
  @[Security(Level::Support)]
  def get_token
    response = get("/api/auth/token", headers: {
      "Accept" => "text"
    })
    raise "issue obtaining token: #{response.status_code}" unless response.success?
    response.body
  end

  def example
    xml = %(<?xml version="1.0" encoding="UTF-8"?>

    <ns2:count-data xmlns:ns2="http://www.xovis.com/count-data" xmlns:ns3="http://www.xovis.com/count-data">
      <ns2:count-items>
        <ns2:lines>
          <ns2:line name="Line 0" id="0" sensor-type="SINGLE_SENSOR">
            <fw-count>0</fw-count>
            <bw-count>0</bw-count>
          </ns2:line>
        </ns2:lines>
      </ns2:count-items>
      <ns2:sensor-time>2020-05-05T11:20:47+02:00</ns2:sensor-time>
      <ns2:request-status>
        <ns3:status>OK</ns3:status>
      </ns2:request-status>
    </ns2:count-data>)

    document = XML.parse(xml)
    document.xpath_nodes("//ns2:line")
    document.xpath_nodes("//ns2:sensor-time")[0].text
  end
end
