require "placeos-driver"

class InnerRange::Integriti < PlaceOS::Driver
  descriptive_name "Integriti HID Origo trigger"
  generic_name :HID_Origo

  default_settings({
    custom_field_hid_origo: "cf_HasVirtualCard",
    # with no HID module, re-issue by unticking the custom field, waiting for
    # Integriti to revoke the user's mobile credentials, then ticking it again
    reissue_through_integriti: false,
    reissue_timeout_seconds:   300,
  })

  accessor staff_api : StaffAPI_1
  accessor integriti : Integriti_1
  accessor hid_origo : HID_1

  def on_update
    @cf_virtual_card = setting?(String, :custom_field_hid_origo) || "cf_HasVirtualCard"
    @reissue_through_integriti = setting?(Bool, :reissue_through_integriti) || false
    @reissue_timeout = (setting?(Int32, :reissue_timeout_seconds) || 300).seconds
  end

  getter cf_virtual_card : String = "cf_HasVirtualCard"
  getter? reissue_through_integriti : Bool = false
  getter reissue_timeout : Time::Span = 300.seconds

  REISSUE_POLL = 5.seconds

  # Integriti user addresses with a re-issue waiting on the re-tick
  @reissuing = Set(String).new

  protected def get_user_email : String
    user_id = invoked_by_user_id
    raise "current user not known in this context" unless user_id
    id = user_id.as(String)
    user = staff_api.user(id).get
    (user["login_name"]?.try(&.as_s?).presence || user["email"].as_s).downcase
  end

  protected def get_integriti_id : String
    email = get_user_email
    integriti.user_id_lookup(email).get[0].as_s
  end

  # The native app matches this prefix to tell the user to contact support.
  REISSUE_UNAVAILABLE = "virtual_card_reissue_unavailable"

  def request_virtual_card : Nil
    id = get_integriti_id
    return if @reissuing.includes?(id)

    if has_virtual_card?
      if system.exists?(:HID, 1)
        hid_origo.invite_user_email(get_user_email).get
      elsif reissue_through_integriti?
        reissue_through_integriti(id)
      else
        raise "#{REISSUE_UNAVAILABLE}: a virtual card has already been issued to this user and this system has no HID module to issue another"
      end
    else
      integriti.update_entry("User", id, {cf_virtual_card => true}).get
    end
  end

  # Returns once the custom field is unticked; the re-tick happens in the
  # background after Integriti revokes the user's mobile credentials or
  # `reissue_timeout` passes, whichever is first.
  protected def reissue_through_integriti(id : String) : Nil
    integriti.update_entry("User", id, {cf_virtual_card => false}).get
    @reissuing << id
    deadline = Time.utc + reissue_timeout
    spawn { retick_once_revoked(id, deadline) }
  end

  protected def retick_once_revoked(id : String, deadline : Time) : Nil
    loop do
      sleep REISSUE_POLL
      active = begin
        active_mobile_credential?(id)
      rescue error
        logger.warn(exception: error) { "checking #{id}'s mobile credentials failed" }
        true
      end
      break unless active
      if Time.utc >= deadline
        logger.warn { "#{id} still has an active mobile credential after #{reissue_timeout}, ticking #{cf_virtual_card} again anyway" }
        break
      end
    end
    integriti.update_entry("User", id, {cf_virtual_card => true}).get
  rescue error
    logger.error(exception: error) { "re-ticking #{cf_virtual_card} for #{id} failed" }
  ensure
    @reissuing.delete(id)
  end

  # Card states are Active* or Inactive*. A credential that Integriti deletes
  # on revoke disappears from the list.
  protected def active_mobile_credential?(id : String) : Bool
    integriti.cards(user_id: id).get.as_a.any? do |card|
      card["cloud_credential_id"]?.try(&.as_s?).presence &&
        card["state"]?.try(&.as_s?).try(&.starts_with?("Active"))
    end
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
