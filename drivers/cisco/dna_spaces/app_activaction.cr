require "./events"

class Cisco::DNASpaces::AppActivaction
  include JSON::Serializable

  @[JSON::Field(key: "spacesTenantName")]
  getter spaces_tenant_name : String

  @[JSON::Field(key: "spacesTenantId")]
  getter spaces_tenant_id : String

  @[JSON::Field(key: "partnerTenantId")]
  getter partner_tenant_id : String
  getter name : String

  @[JSON::Field(key: "referenceId")]
  getter reference_id : String

  @[JSON::Field(key: "instanceName")]
  getter instance_name : String
end
