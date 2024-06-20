require "placeos-driver"
require "desigo"

class Siemens::Desigo < PlaceOS::Driver
  descriptive_name "Siemens Desigo Gateway"
  generic_name :Desigo
  uri_base "https://127.0.0.1:8080/WebService/api/"

  alias Client = ::Desigo::Client

  default_settings({
    username: "admin",
    password: "admin",
  })

  protected getter! client : Client

  def on_load
    on_update
  end

  def on_update
    base_url = config.uri.not_nil!.to_s
    username = setting(String, :username)
    password = setting(String, :password)

    @client = Client.new(base_url: base_url, username: username, password: password)

    spawn do
      loop do
        @client.try(&.heartbeat.signal)
        sleep 60
      end
    end
  end

  def property_values(id : String)
    property_values = @client.try(&.property_values.get(id: id))
    self["property_values#{id}"] = property_values
  end

  def values(id : String)
    values = @client.try(&.values.get(id: id))
    self["values#{id}"] = values
  end

  def commands(id : String)
    commands = @client.try(&.commands.get(id: id))
    self["commands#{id}"] = commands
  end

  # Because of the introspect failing on generics,
  # we can pass in the `command_inputs_for_execution` as a JSON string
  # "[{\"Name\": \"Value\", \"DataType\": \"ExtendedEnum\", \"Value\": \"1\"}]"
  def execute(id : String, property_name : String, command_id : String, command_inputs_for_execution : String)
    return_value = @client.try(&.commands.execute(id: id, property_name: property_name, command_id: command_id, command_inputs_for_execution: JSON.parse(command_inputs_for_execution)))
    self["execute#{id}_property#{property_name}_command#{command_id}"] = return_value
  end
end
