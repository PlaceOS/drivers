require "json"
require "base64"
require "uri"
require "connect-proxy"
require "simple_retry"
require "./lib"
require "jwt"
require "./actions"

module WebxWorkspace
  enum KeyType
    EC
  end

  record ECKey, kid : String, kty : KeyType, use : String, alg : String, crv : String, x : String, y : String do
    include JSON::Serializable
    include JSON::Serializable::Unmapped

    def pub_key : String
      raise "Workspace integration requires Key type to be EC only" unless kty == KeyType::EC

      curve_nid = curve_to_nid(crv)
      x_bin = base64url_decode(x)
      y_bin = base64url_decode(y)

      group = LibCrypto.ec_group_new_by_curve_name(curve_nid)
      point = LibCrypto.ec_point_new(group)

      x_bn = OpenSSL::BN.from_bin(x_bin)
      y_bn = OpenSSL::BN.from_bin(y_bin)

      LibCrypto.ec_point_set_affine_coordinates(group, point, x_bn, y_bn, nil)
      ec_key = LibCrypto.ec_key_new
      LibCrypto.ec_key_set_group(ec_key, group)
      LibCrypto.ec_key_set_public_key(ec_key, point)

      io = IO::Memory.new
      bio = OpenSSL::BIO.new(io)
      LibCrypto.pem_write_bio_ec_pubkey(bio, ec_key)
      pem = io.to_s

      LibCrypto.ec_point_free(point)
      LibCrypto.ec_group_free(group)
      LibCrypto.ec_key_free(ec_key)
      pem
    end

    private def curve_to_nid(curve : String) : Int32
      case curve
      when "P-256" then LibCrypto::NID_X9_62_prime256v1
      when "P-384" then LibCrypto::NID_secp384r1
      when "P-521" then LibCrypto::NID_secp521r1
      else              raise "Unsupported curve: #{curve}"
      end
    end

    private def base64url_decode(input : String) : Bytes
      normalized = input.gsub('-', '+').gsub('_', '/')
      padding = (4 - normalized.size % 4) % 4
      normalized += "=" * padding
      Base64.decode(normalized)
    end
  end

  class KeySet
    getter! keys : Array(ECKey)
    getter url : URI
    @client : ConnectProxy::HTTPClient

    def initialize(@url, proxy_config = nil)
      @client = WebxWorkspace.new_client(url, proxy_config)
    end

    private def load
      SimpleRetry.try_to(
        max_attempts: 3,
        retry_on: Exception,
        base_interval: 2.milliseconds,
      ) do |_|
        resp = @client.get(url.request_target)
        raise "unable to retrieve key set from url #{url}" unless resp.success?
        @keys = Array(ECKey).from_json(resp.body, "keys")
      end
    end

    def [](kid : String) : ECKey
      load unless keys?
      found = keys.select { |key| key.kid == kid }
      raise "invalid key id '#{kid}', not found in server retrieved keyset" if found.empty?
      found.first
    end
  end

  class JWTDecoder
    REGIONAL_KEY_SET_URLS = {
      "us-west-2_r"      => URI.parse("https://xapi-r.wbx2.com/jwks"),
      "us-east-2_a"      => URI.parse("https://xapi-a.wbx2.com/jwks"),
      "eu-central-1_k"   => URI.parse("https://xapi-k.wbx2.com/jwks"),
      "us-east-1_int13"  => URI.parse("https://xapi-intb.wbx2.com/jwks"),
      "us-gov-west-1_a1" => URI.parse("https://xapi.gov.ciscospark.com/jwks"),
    } of String => URI

    property default_region : String = "us-east-2_a"
    @verification_keys : KeySet?
    @proxy_config : WebxWorkspace::ProxyConfig?

    def initialize(@proxy_config = nil)
    end

    def decode_action(jwt : String) : Action
      verified = verify_jws(jwt)
      Action.from_json(verified.to_json)
    end

    private def key_set(region) : KeySet
      url = REGIONAL_KEY_SET_URLS[region]? || REGIONAL_KEY_SET_URLS[default_region]
      @verification_keys ||= KeySet.new(url, @proxy_config)
    end

    private def verify_jws(jwt : String)
      claims, header = JWT.decode(token: jwt, verify: false, validate: false)
      type = header["typ"].as_s
      algo = JWT::Algorithm.parse(header["alg"].as_s)
      kid = header["kid"].as_s
      raise "invalid token type '#{type}', expected token of type JWT" unless type == "JWT"
      raise "invalid jwt algorithm '#{algo}', workspace integration required algorithm is ES256" unless algo == JWT::Algorithm::ES256

      region = claims.as_h["region"]?.try &.as_s? || default_region

      ec_pubkey = key_set(region)[kid].pub_key
      payload, _ = JWT.decode(token: jwt, key: ec_pubkey, algorithm: algo, verify: true, validate: true)
      payload
    end
  end
end
