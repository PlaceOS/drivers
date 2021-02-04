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
    poll_rate: 15,
  })

  def on_load
    on_update
  end

  @poll_rate : Time::Span = 15.seconds

  def on_update
    @poll_rate = (setting?(Int32, :poll_rate) || 15).seconds
    schedule.clear
    schedule.every(@poll_rate) do
      count_data
      capacity_data
    end
    schedule.every(5.minutes) { device_status }
    schedule.in(5.seconds) do
      count_data
      capacity_data
      device_status
    end
  end

  # Alternative to using basic auth, but here really only for testing with postman
  @[Security(Level::Support)]
  def get_token
    response = get("/api/auth/token", headers: {"Accept" => "text"})
    raise "issue obtaining token: #{response.status_code}\n#{response.body}" unless response.success?
    response.body
  end

  @[Security(Level::Support)]
  def get_logs
    response = get("/api/info/log", headers: {"Accept" => "text"})
    raise "issue obtaining logs: #{response.status_code}\n#{response.body}" unless response.success?
    response.body
  end

  @[Security(Level::Support)]
  def reset_count
    response = get("/api/count-data/reset", headers: {"Accept" => "text/xml"})
    check_success(response)
    true
  end

  def is_alive?
    response = get("/api/info/alive", headers: {"Accept" => "text/xml"})
    check_success(response)
    true
  rescue
    false
  end

  def count_data
    response = get("/api/count-data", headers: {"Accept" => "text/xml"})
    document = check_success(response)

    lines = {} of String => NamedTuple(name: String, id: String, type: String, sensor: String, data: Hash(String, String | Int32 | Float32))
    lines_xml = document.xpath_nodes("//lines/line")

    self[:lines] = lines_xml.map do |line|
      attrs = {} of String => String | Hash(String, Int32)
      counts = {} of String => Int32
      line.attributes.each { |attr| attrs[attr.name] = attr.content }
      line.children.each { |child|
        next if child.name == "text"
        counts[child.name] = child.text.to_i
      }
      attrs["counts"] = counts
      attrs
    end
  end

  def capacity_data
    response = get("/api/info/persistence", headers: {"Accept" => "text/xml"})
    document = check_success(response)

    {"line", "zone-occupancy", "zone-in-out"}.each do |count_name|
      xml_key_name = "//count-#{count_name}-storage"
      if count_data = document.xpath_nodes(xml_key_name).first?
        count_type = count_name.split("-", 2)[0]
        capacity = xpath_text(document, "#{xml_key_name}/capacity", &.to_i)

        self["#{count_name}-counts"] = document.xpath_nodes("#{xml_key_name}/count-#{count_type}s/count-#{count_type}").map do |zone|
          attrs = {} of String => String | Int32 | Time | Nil

          zone.children.each do |child|
            content = child.text.strip
            attrs[child.name] = case child.name
                                when "entry-count"
                                  content.to_i
                                when "first-entry", "last-entry"
                                  content.empty? ? nil : Time.parse!(content, "%Y-%m-%dT%H:%M:%S%z")
                                when "text"
                                  next
                                else
                                  content
                                end
          end

          attrs["capacity"] = capacity
          attrs
        end
      end
    end
    true
  end

  # Combined `/info` and `/info/status`
  def device_status
    response = get("/api/info/sensor-status", headers: {"Accept" => "text/xml"})
    document = check_success(response)

    parse_type_info(document, "version")
    parse_type_info(document, "temperature")

    parse_text_info(document, "sensor")
    parse_text_info(document, "illumination")
    parse_text_info(document, "configuration")
    parse_text_info(document, "operation")

    true
  end

  protected def xpath_text(document, path)
    document.xpath_nodes(path).first?.try(&.text.strip)
  end

  protected def xpath_text(document, path)
    if node = document.xpath_nodes(path).first?
      yield node.text.strip
    end
  end

  protected def parse_type_info(document, xpath_key) : Nil
    ver_data = document.xpath_nodes("//#{xpath_key}s/#{xpath_key}")
    attrs = {} of String => String
    ver_data.each do |data|
      key = data.attributes.select { |attr| attr.name == "type" }.first?.try &.content
      next unless key
      attrs[key] = data.text.strip
    end
    self[xpath_key] = attrs.empty? ? nil : attrs
  end

  protected def parse_text_info(document, status) : Nil
    if keys = document.xpath_nodes("//#{status}").first?.try(&.children)
      attrs = {} of String => String
      keys.each do |data|
        key = data.name
        next if key == "text"
        attrs[key.underscore] = data.text.strip
      end
      self[status] = attrs.empty? ? nil : attrs
    else
      self[status] = nil
    end
  end

  protected def check_success(response)
    raise "issue with request: #{response.status_code}\n#{response.body}" unless response.success?
    document = parse_without_namespaces(response.body)
    status = document.xpath_nodes("//request-status/status").first?.try &.text.strip
    raise "request failed with #{status}\n#{response.body}" unless status == "OK"
    sensor_time(document)
    document
  end

  protected def sensor_time(document) : Time?
    if time_text = document.xpath_nodes("//sensor-time").first?.try &.text
      self[:sensor_time] = Time.parse!(time_text, "%Y-%m-%dT%H:%M:%S%z")
    end
  end

  protected def parse_without_namespaces(xml : String)
    xml = xml.strip
    document = XML.parse(xml)
    namespace_node = document.children[0].name == "xml" ? document.children[1].name : document.children[0].name
    namespaces = document.children[0].namespaces.keys.compact_map { |name| name.starts_with?("xmlns:") ? "#{name[6..-1]}\\:" : nil }

    # Clean up namespaces from node names
    xml = xml.gsub(Regex.new(namespaces.join("|")), "")
    # Replace namespace node
    xml = xml.sub(Regex.new("<#{namespace_node}.+>"), "<#{namespace_node}>")

    # Return the parsed document
    XML.parse(xml)
  end
end
