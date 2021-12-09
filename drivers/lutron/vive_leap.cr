require "placeos-driver"
require "placeos-driver/interface/sensor"

class Lutron::ViveLeap < PlaceOS::Driver
  include Interface::Sensor

  # Discovery Information
  descriptive_name "Lutron Vive LEAP"
  generic_name :Lighting

  # Requires TLS negotiation (max 10 connections)
  tcp_port 8081

  def on_load
    on_update
  end

  def on_update

  end

  # this request needs to be made before anything else to negotiate protocol version
  def client_setting
    request = Request.new("/clientsetting", :update_request, {
      ClientSetting: {
        ClientMajorVersion: 1
      }
    })
    send request.to_json, priority: 99, name: request.name?
  end

  def received(data, task)
    logger.debug { "Lutron sent: #{data}" }
    request = Request.from_json(data)

    url = request["Url"]?
    status = request["StatusCode"]? || "200 OK"
    message_type = request["MessageBodyType"]?

    # check status code
    code, status = status.split(" ", 2)
    code = code.to_i
    if code != 200 # TODO:: check between 200 and 299 (can be 204 etc)
      error_message = "operation #{url} failed with #{code}: #{status}"
      logger.warn { error_message }
      if task && task.name == url
        task.abort error_message
      else
        task.ignore
      end
      return
    end

    # process the message based on its type by preference
    case message_type
    when "OneClientSettingDefinition"
      setting = ClientSetting.from_json request.body
      logger.debug { "protocol version negotiated #{setting.protocol.version}, authenticating" }
      authenticate
    when nil
      case url
      when "/server/status/ping"
        logger.debug { "got ping response" }
      end
    else
      logger.debug { "unknown message type #{message_type}" }
    end

    task.try &.success
  end
end
