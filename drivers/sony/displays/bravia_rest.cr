require "placeos-driver"
require "placeos-driver/interface/powerable"
require "placeos-driver/interface/muteable"
require "placeos-driver/interface/switchable"

# Documentation: https://pro-bravia.sony.net/develop/integrate/rest-api/spec/
class Sony::Displays::BraviaRest < PlaceOS::Driver
  include Interface::Powerable
  include Interface::Muteable

  # Discovery Information
  uri_base "http://display"
  descriptive_name "Sony Bravia REST API Display"
  generic_name :Display
  description "Sony Bravia Professional Display controlled via REST API. Requires Pre-Shared Key (PSK) authentication."

  default_settings({
    psk: "your_psk_here",
  })

  enum Input
    HDMI1            =  1
    HDMI2            =  2
    HDMI3            =  3
    HDMI4            =  4
    Component1       =  5
    Component2       =  6
    Component3       =  7
    Composite1       =  8
    Screen_mirroring =  9
    PC               = 10

    def to_uri : String
      case self
      when .hdmi1?, .hdmi2?, .hdmi3?, .hdmi4?
        "extInput:hdmi?port=#{value}"
      when .component1?, .component2?, .component3?
        "extInput:component?port=#{value - 4}"
      when .composite1?
        "extInput:composite?port=1"
      when .screen_mirroring?
        "extInput:widi?port=1"
      when .pc?
        "extInput:cec?port=1"
      else
        "extInput:hdmi?port=1"
      end
    end
  end

  include Interface::InputSelection(Input)

  @psk : String = ""

  def on_load
    self[:volume_min] = 0
    self[:volume_max] = 100
    on_update
  end

  def on_update
    @psk = setting(String, :psk)
  end

  def connected
    schedule.every(30.seconds, true) do
      do_poll
    end
  end

  def disconnected
    schedule.clear
  end

  def power(state : Bool)
    send_command("system", "setPowerStatus", {status: state})
    power?
  end

  def power?
    send_command("system", "getPowerStatus", [] of String)
  end

  def mute(
    state : Bool = true,
    index : Int32 | String = 0,
    layer : MuteLayer = MuteLayer::AudioVideo,
  )
    send_command("audio", "setAudioMute", {status: state})
    mute?
  end

  def unmute
    mute false
  end

  def mute?
    send_command("audio", "getVolumeInformation", [] of String)
  end

  def volume(level : Int32 | Float64)
    level = level.to_f.clamp(0.0, 100.0).round_away.to_i
    send_command("audio", "setAudioVolume", {volume: level.to_s, target: "speaker"})
    volume?
  end

  def volume?
    send_command("audio", "getVolumeInformation", [] of String)
  end

  def volume_up
    send_command("audio", "setAudioVolume", {volume: "+5", target: "speaker"})
    volume?
  end

  def volume_down
    send_command("audio", "setAudioVolume", {volume: "-5", target: "speaker"})
    volume?
  end

  def switch_to(input : Input)
    logger.debug { "switching input to #{input}" }
    send_command("avContent", "setPlayContent", {uri: input.to_uri})
    self[:input] = input.to_s
    input?
  end

  def input?
    send_command("avContent", "getPlayingContentInfo", [] of String)
  end

  def do_poll
    if status?(Bool, :power)
      volume?
      mute?
      input?
    end
  end

  private def send_command(service : String, method : String, params)
    headers = HTTP::Headers{
      "Content-Type" => "application/json",
      "X-Auth-PSK"   => @psk,
    }

    body = {
      method:  method,
      id:      Random.rand(1..999),
      params:  [params],
      version: "1.0",
    }.to_json

    response = post("/sony/#{service}", body: body, headers: headers)

    unless response.success?
      logger.error { "HTTP error: #{response.status_code} - #{response.body}" }
      raise "HTTP Error: #{response.status_code}"
    end

    data = JSON.parse(response.body)

    if error = data["error"]?
      logger.error { "Sony Bravia API error: #{error}" }
      raise "API Error: #{error}"
    end

    result = data["result"]?
    process_response(method, result)
    result
  end

  private def process_response(method : String, result)
    case method
    when "getPowerStatus"
      if result.responds_to?(:as_a) && (array = result.as_a?) && array.size > 0
        status = array[0].as_h
        power_status = status["status"]?.try(&.as_s) == "active"
        self[:power] = power_status
      end
    when "getVolumeInformation"
      if result.responds_to?(:as_a) && (array = result.as_a?) && array.size > 0
        volume_info = array[0].as_a
        volume_info.each do |info|
          vol_data = info.as_h
          if vol_data["target"]?.try(&.as_s) == "speaker"
            self[:volume] = vol_data["volume"]?.try(&.as_i) || 0
            self[:mute] = vol_data["mute"]?.try(&.as_bool) || false
            break
          end
        end
      end
    when "getPlayingContentInfo"
      if result.responds_to?(:as_a) && (array = result.as_a?) && array.size > 0
        content_info = array[0].as_h
        uri = content_info["uri"]?.try(&.as_s) || ""
        self[:input] = parse_input_from_uri(uri)
      end
    end
  end

  private def parse_input_from_uri(uri : String) : String
    if uri.includes?("hdmi")
      if match = uri.match(/port=(\d+)/)
        port = match[1].to_i
        case port
        when 1 then "HDMI1"
        when 2 then "HDMI2"
        when 3 then "HDMI3"
        when 4 then "HDMI4"
        else        "HDMI1"
        end
      else
        "HDMI1"
      end
    elsif uri.includes?("component")
      if match = uri.match(/port=(\d+)/)
        port = match[1].to_i
        case port
        when 1 then "Component1"
        when 2 then "Component2"
        when 3 then "Component3"
        else        "Component1"
        end
      else
        "Component1"
      end
    elsif uri.includes?("composite")
      "Composite1"
    elsif uri.includes?("widi")
      "Screen_mirroring"
    elsif uri.includes?("cec")
      "PC"
    else
      "Unknown"
    end
  end
end
