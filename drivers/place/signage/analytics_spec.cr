require "placeos-driver/spec"

# Mock of the StaffAPI driver exposing just the `systems` query the
# analytics driver relies on.
class StaffAPI < DriverSpecs::MockDriver
  # Return a mix of signage systems:
  # - two recently seen (online)
  # - one seen long ago (offline)
  # - one that has never checked in (ignored)
  def systems(
    zone_id : String? = nil,
    signage : Bool? = nil,
    q : String? = nil,
    capacity : Int32? = nil,
    bookable : Bool? = nil,
    limit : Int32 = 1000,
  )
    now = Time.utc.to_unix
    payload = [
      {id: "sys-online-1", signage_last_seen: now},
      {id: "sys-online-2", signage_last_seen: now - 60},
      {id: "sys-offline-1", signage_last_seen: now - 600},
      {id: "sys-never", signage_last_seen: nil},
    ]
    JSON.parse(payload.to_json)
  end
end

DriverSpecs.mock_driver "Place::Signage::Analytics" do
  system({
    StaffAPI: {StaffAPI},
  })

  settings({
    poll_rate: 5,
    org_zone:  "zone-XYZ",
  })

  exec(:query_signage_checkin_status).get

  # per-system online state (never-seen system is skipped entirely)
  status["sys-online-1"].should eq(1)
  status["sys-online-2"].should eq(1)
  status["sys-offline-1"].should eq(0)
  status["sys-never"]?.should be_nil

  # overview aggregates only systems that have checked in at least once
  overview = status[:overview].as_h
  overview["total"].should eq(3)
  overview["online"].should eq(2)
  overview["offline"].should eq(1)
  overview["percent"].should eq(66.67)
end
