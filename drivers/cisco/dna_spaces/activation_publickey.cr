require "./events"

class Cisco::DNASpaces::ActivactionPublicKey
  include JSON::Serializable

  getter version : String

  @[JSON::Field(key: "publicKey")]
  getter public_key : String

  def public_key
    "-----BEGIN PUBLIC KEY-----\n#{@public_key}\n-----END PUBLIC KEY-----\n"
  end
end
