require "json"

class Place::Booking
  include JSON::Serializable

  # This is to support events
  property action : String?

  property id : Int64
  property booking_type : String
  property booking_start : Int64
  property booking_end : Int64
  property timezone : String?

  # events use resource_id instead of asset_id
  property asset_id : String?
  property resource_id : String?

  def asset_id : String
    (@asset_id || @resource_id).not_nil!
  end

  property user_id : String
  property user_email : String
  property user_name : String

  property zones : Array(String)

  property checked_in : Bool?
  property rejected : Bool?
  property approved : Bool?
  property process_state : String?
  property last_changed : Int64?

  property approver_name : String?
  property approver_email : String?

  property booked_by_name : String
  property booked_by_email : String

  property checked_in : Bool { false }
  property title : String?
  property description : String?

  property extension_data : Hash(String, JSON::Any) { {} of String => JSON::Any }

  def in_progress?
    now = Time.utc.to_unix
    now >= @booking_start && now < @booking_end
  end

  def changed
    Time.unix(last_changed.not_nil!)
  end
end
