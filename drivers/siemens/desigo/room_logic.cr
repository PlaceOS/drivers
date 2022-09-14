require "placeos-driver"

class Siemens::Desigo::RoomLogic < PlaceOS::Driver
  descriptive_name "Siemens Desigo single room status abstraction"
  generic_name :RoomBMS
  description "Exposes Desigo values for a single room"

  default_settings({
    desigo_queries:          [] of Query,
    desigo_status_poll_cron: "*/5 * * * *",
  })

  accessor desigo : Desigo

  @queries = [] of Query
  @cron_string : String = "*/5 * * * *"

  def on_load
    on_update
  end

  def on_update
    @queries = setting(Array(Query), :desigo_queries)
    @cron_string = setting(String, :do_queries)
    schedule.cron(@cron_string) { do_queries }
  end

  def do_queries
    responses = @queries.map { |q| {q.name, desigo.values(q.param).get} }
    responses.each { |name, value| self[name] = value.as_a.first.as_h["Value"]["Value"] }
  end

  struct Query
    include JSON::Serializable
    getter name : String
    property command : String # todo: support different commands
    property param : String   # todo: support multiple params
  end
end
