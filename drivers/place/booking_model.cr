require "json"

class Place::Booking
  include JSON::Serializable

  # This is to support events
  property action : String? = nil

  property id : Int64
  property instance : Int64? = nil
  property booking_type : String
  property booking_start : Int64
  property booking_end : Int64
  property timezone : String?

  # events use resource_id instead of asset_id
  property asset_id : String?
  property asset_ids : Array(String) = [] of String
  property resource_id : String?

  def asset_id : String
    (@asset_id || @resource_id).as(String)
  end

  property user_id : String
  property user_email : String
  property user_name : String

  property zones : Array(String)

  property rejected : Bool?
  property rejected_at : Int64? = nil
  property approved : Bool?
  property process_state : String?
  property last_changed : Int64?
  property created : Int64?

  property approver_id : String?
  property approver_name : String?
  property approver_email : String?

  property booked_by_id : String?
  property booked_by_name : String
  property booked_by_email : String

  property checked_out_at : Int64? = nil
  property deleted : Bool? = nil
  property checked_in : Bool { false }
  property title : String?
  property description : String?

  property extension_data : Hash(String, JSON::Any) { {} of String => JSON::Any }
  getter recurrence_type : String? = nil

  property all_day : Bool = false

  def recurring?
    @recurrence_type != "none"
  end

  def recurring_master?
    recurring? && instance.nil?
  end

  def in_progress?
    now = Time.utc.to_unix
    now >= @booking_start && now < @booking_end
  end

  def changed
    Time.unix(last_changed.not_nil!)
  end

  def expand
    return {self}.each if asset_ids.size < 2

    asset_ids.map do |aid|
      Place::Booking.new(
        id: id,
        booking_type: booking_type,
        booking_start: booking_start,
        booking_end: booking_end,
        user_id: user_id,
        user_email: user_email,
        user_name: user_name,
        zones: zones,
        booked_by_name: booked_by_name,
        booked_by_email: booked_by_email,
        action: action,
        timezone: timezone,
        asset_id: aid,
        resource_id: resource_id,
        checked_in: checked_in,
        rejected: rejected,
        approved: approved,
        process_state: process_state,
        last_changed: last_changed,
        approver_name: approver_name,
        approver_email: approver_email,
        title: title,
        description: description,
        asset_ids: [aid],
        created: created,
        approver_id: approver_id,
        booked_by_id: booked_by_id,
        extension_data: extension_data,
      )
    end
  end

  def initialize(
    @id,
    @booking_type,
    @booking_start,
    @booking_end,
    @user_id,
    @user_email,
    @user_name,
    @zones,
    @booked_by_name,
    @booked_by_email,
    @action = nil,
    @timezone = nil,
    @asset_id = nil,
    @resource_id = nil,
    @checked_in = nil,
    @rejected = nil,
    @approved = nil,
    @process_state = nil,
    @last_changed = nil,
    @approver_name = nil,
    @approver_email = nil,
    @title = nil,
    @description = nil,
    @asset_ids = [] of String,
    @created = nil,
    @approver_id = nil,
    @booked_by_id = nil,
    @instance = nil,
    @extension_data = nil,
  )
    asset = asset_id.presence
    if @asset_ids.empty?
      @asset_ids << asset if asset
    elsif asset.nil?
      @asset_id = @asset_ids.first
    end
  end
end
