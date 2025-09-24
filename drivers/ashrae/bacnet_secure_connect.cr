require "placeos-driver"

# docs: https://bacnet.org/wp-content/uploads/sites/4/2022/08/Add-135-2016bj.pdf

class Ashrae::BACnetSecureConnect < PlaceOS::Driver
  generic_name :BACnet
  descriptive_name "BACnet Secure Connect"
  description "BACnet over websockets"

  uri_base "wss://server.domain.or.ip:port/"

  default_settings({
    _https_client_cert: "In PEM format typically required",
  })

  @[Security(Level::Support)]
  def send_message(hex : String)
    send hex.hexbytes, wait: false
  end

  def received(data, task)
    logger.debug { "websocket sent: 0x#{data.hexstring}" }
    task.try &.success
  end
end
