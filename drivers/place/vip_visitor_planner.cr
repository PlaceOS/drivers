require "json"

# Uses the Planner methods on Calendar_1 (Microsoft Graph calendar driver).
# The caller owns persistence and serializes work for each booking.
module Place::VIPVisitorPlanner
  private def provision_plan(booking : JSON::Any, state : Hash(String, JSON::Any), &checkpoint : ->)
    return if state["planner_complete"]?.try(&.as_bool?) == true

    group_id = setting(String, :planner_group_id).strip
    raise "planner_group_id must identify an existing Microsoft 365 group" if group_id.empty?
    tasks = vip_planner_tasks(booking)
    assignments = setting?(Hash(String, Array(String)), :planner_task_assignments) || {} of String => Array(String)

    unless state["plan_id"]?
      name = booking["extension_data"]?.try(&.["vip_full_name"]?).try(&.as_s?).presence ||
             booking["title"]?.try(&.as_s?).presence || "VIP Visit"
      title = "#{name} - VIP Visit (#{booking["id"]})"
      raise "Planner plan title exceeds 255 characters" if title.size > 255
      result = calendar.create_plan(group_id, title).get
      state["plan_id"] = JSON::Any.new(vip_planner_id(result))
      yield
    end
    plan_id = state["plan_id"].as_s

    buckets = state["bucket_ids"]?.try(&.as_h) || {} of String => JSON::Any
    state["bucket_ids"] = JSON::Any.new(buckets)
    {"To Do", "In Progress", "Done"}.each do |name|
      next if buckets[name]?
      # Place each bucket after the preceding one, using the service's hint.
      # https://learn.microsoft.com/en-us/graph/api/resources/planner-order-hint-format
      order_hint = "#{state["bucket_order_hint"]?.try(&.as_s) || ""} !"
      result = calendar.create_bucket(plan_id, name, order_hint).get
      buckets[name] = JSON::Any.new(vip_planner_id(result))
      state["bucket_order_hint"] = result["orderHint"]? || JSON::Any.new(order_hint)
      yield
    end

    task_ids = state["task_ids"]?.try(&.as_h) || {} of String => JSON::Any
    state["task_ids"] = JSON::Any.new(task_ids)
    due_at = booking["booking_start"]?.try(&.as_i64?).try { |value| Time.unix(value).to_rfc3339 }
    tasks.each do |key, title|
      next if task_ids[key]?
      result = calendar.create_task(
        plan_id: plan_id,
        title: title,
        bucket_id: buckets["To Do"].as_s,
        assigned_to_user_ids: assignments[key]?,
        due_date_time: due_at,
        percent_complete: 0,
      ).get
      task_ids[key] = JSON::Any.new(vip_planner_id(result))
      yield
    end
    state["planner_complete"] = JSON::Any.new(true)
    yield
  end

  private def vip_planner_id(result : JSON::Any) : String
    id = result["id"]?.try(&.as_s?).presence
    raise "Calendar returned no Planner resource ID" unless id
    id
  end

  private def vip_planner_tasks(booking : JSON::Any) : Hash(String, String)
    data = booking["extension_data"]?.try(&.as_h?) || {} of String => JSON::Any
    tasks = {} of String => String
    if value = vip_planner_option(data, "meet_greet")
      label = case value.downcase
              when "internal"                                          then "Internal"
              when "airport", "external - airport", "external_airport" then "Airport"
              else                                                          value
              end
      tasks["meet_greet"] = "Meet & Greet - #{label}"
    end
    {
      "tour"           => "Walkthrough/Guided Tour",
      "gift"           => "Giveaway Gift",
      "photographer"   => "Photographer",
      "welcome_screen" => "Welcome screen",
      "presentation"   => "Presentation",
    }.each do |key, title|
      selected = key == "tour" ? (data[key]? || data["walkthrough"]?) : data[key]?
      tasks[key] = title if selected.try(&.as_bool?) == true
    end
    beverage_key = data.has_key?("beverage_preference") ? "beverage_preference" : "welcome_beverage"
    if value = vip_planner_option(data, beverage_key)
      notes = data["beverage_notes"]?.try(&.as_s?).presence ||
              data["welcome_beverage_notes"]?.try(&.as_s?).presence ||
              data["welcome_beverage_custom"]?.try(&.as_s?).presence
      tasks["welcome_beverage"] = "Welcome Beverage - #{value}#{notes ? ": #{notes}" : ""}"
    end
    if restaurant = data["restaurant_reservation"]?.try(&.as_h?)
      name = restaurant["name"]?.try(&.as_s?).presence
      timestamp = restaurant["time"]?.try(&.as_i64?)
      raise "Restaurant reservation requires name and Unix time" unless name && timestamp
      zone = Time::Location.load(setting?(String, :timezone) || "Asia/Dubai")
      time = Time.unix(timestamp).in(zone).to_s("%Y-%m-%d %H:%M %z")
      address = restaurant["address"]?.try(&.as_s?).presence
      tasks["restaurant_reservation"] = "Restaurant Reservation - #{name}#{address ? ", #{address}" : ""} - #{time}"
    end
    if value = vip_planner_option(data, "driver")
      label = case value.downcase
              when "in_house", "in-house"       then "In-house"
              when "third_party", "third party" then "Third Party"
              else                                   value
              end
      tasks["driver"] = "Driver - #{label}"
    end
    tasks.each do |key, title|
      # Calendar currently has no task-details API. Keep all requested details
      # in the title and fail explicitly rather than silently dropping data.
      raise "Planner task #{key} exceeds 255 characters" if title.size > 255
    end
    tasks
  end

  private def vip_planner_option(data : Hash(String, JSON::Any), key : String) : String?
    value = data[key]?.try(&.as_s?).try(&.strip)
    return nil if value.nil? || value.empty? || value.downcase == "none"
    value
  end
end
