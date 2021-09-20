require "./models"

class Vergesense::MqttExport < PlaceOS::Driver
  descriptive_name "Vergesense to MQTT Exporter"
  generic_name :VergesenseToMQTT
  description %(Export Vergesense people count data to an MQTT consumer)

  accessor vergesense : Vergesense_1
  accessor mqtt : GenericMQTT_1

  default_settings({
    mqtt_root_topic:  "/t/root-topic/",
    floors_to_export: [
      "vergesense_building_id-floor_id",
    ],
    debug: false,
  })

  @mqtt_root_topic : String = "/t/root-topic/"
  @floors_to_export : Array(String) = [] of String
  @debug : Bool = false

  @subscriptions : Int32 = 0
  @previous_counts = Hash(String, UInt32).new

  def on_load
    on_update
  end

  def on_update
    @mqtt_root_topic = setting(String, :mqtt_root_topic) || "/t/root-topic"
    @floors_to_export = setting(Array(String), :floors_to_export) || [] of String
    @debug = setting(Bool, :debug) || false

    subscriptions.clear
    @subscriptions = 0
    @floors_to_export.each do |floor|
      system.subscribe(:Vergesense_1, floor) do |_subscription, vergesense_floor_json|
        vergesense_to_mqtt(Floor.from_json(vergesense_floor_json))
      end
      @subscriptions += 1
    end
  end

  def inspect_state
    {
      vergesense_subscriptions: @subscriptions,
      people_counts:            @previous_counts,
    }
  end

  private def vergesense_to_mqtt(vergesense_floor : Floor)
    # Determine which spaces have had their people count change
    changed_spaces = vergesense_floor.spaces.reject { |s| s.people.try &.count == @previous_counts[s.space_ref_id]? }
    logger.debug { "#{changed_spaces.size}/#{vergesense_floor.spaces.size} spaces have changed" } if @debug
    # Publish the new values
    changed_spaces.each do |s|
      next unless s.space_ref_id
      space_id = s.space_ref_id.not_nil!.gsub(/[ \/]/, "")
      topic = [@mqtt_root_topic, s.building_ref_id, "-", s.floor_ref_id, ".", s.space_type, ".", space_id, ".", "count"].join.downcase
      # Store the current value, for comparison next time
      @previous_counts[space_id] = payload = s.people.try &.count || 0_u32
      mqtt.publish(topic, payload.to_s).get
      logger.debug { "Published #{payload} to #{topic}" } if @debug
    end
  end
end
