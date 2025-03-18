require "openssl_ext"

lib LibCrypto
  NID_secp384r1 = 715
  NID_secp521r1 = 716

  fun ec_group_new_by_curve_name = EC_GROUP_new_by_curve_name(nid : Int32) : EC_GROUP
  fun ec_key_set_private_key = EC_KEY_set_private_key(key : EC_KEY, priv_key : Bignum*) : Int32
  fun ec_key_set_public_key = EC_KEY_set_public_key(key : EC_KEY, pub : EcPoint*) : Int32
  fun ec_point_set_affine_coordinates = EC_POINT_set_affine_coordinates(group : EC_GROUP, p : EcPoint*, x : Bignum*, y : Bignum*, ctx : Void*) : Int32
end
