require "./events"

class AppActivaction
  include JSON::Serializable

  @[JSON::Field(key: "spacesTenantName")]
  getter spaces_tenant_name : String
end
