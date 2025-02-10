require "placeos-driver"

class InnerRange::Integriti < PlaceOS::Driver
  descriptive_name "Integriti HID Origo trigger"
  generic_name :HID_Origo

  default_settings({
    custom_field_hid_origo: "cf_HasVirtualCard",
  })

  accessor staff_api : StaffAPI_1
  accessor integriti : Integriti_1

  def on_update
    @cf_virtual_card = setting?(String, :custom_field_hid_origo) || "cf_HasVirtualCard"
  end

  getter cf_virtual_card : String = "cf_HasVirtualCard"

  protected def get_user_email : String
    user_id = invoked_by_user_id
    raise "current user not known in this context" unless user_id
    id = user_id.as(String)
    user = staff_api.user(id).get
    (user["login_name"]? || user["email"]).as_s.downcase
  end

  protected def get_integriti_id : String
    email = get_user_email
    integriti.user_id_lookup(email).get[0].as_s
  end

  def request_virtual_card : Nil
    id = get_integriti_id
    integriti.update_entry("User", id, {cf_virtual_card => true})
  end

  def remove_virtual_card : Nil
    id = get_integriti_id
    integriti.update_entry("User", id, {cf_virtual_card => false})
  end

  def has_virtual_card? : Bool
    email = get_user_email
    integriti.users(email: email).get.dig?(0, "origo").try(&.as_bool?) || false
  end

  def has_account? : Bool
    email = get_user_email
    integriti.user_id_lookup(email).get.as_a.size > 0
  end
end
