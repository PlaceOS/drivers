require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Demo::Calendar" do
  now = Time.utc.to_unix
  day = now + 86_400
  room = "room@example.com"
  host = "host@example.com"

  # nothing booked yet
  exec(:list_events, room, now, day).get.as_a.should be_empty

  created = exec(:create_event,
    title: "Standup",
    event_start: now + 3600,
    event_end: now + 5400,
    calendar_id: room,
    attendees: [{name: "Host", email: host}, {name: "Room", email: room, resource: true}],
  ).get.not_nil!
  id = created["id"].as_s
  created["event_start"].as_i64.should eq(now + 3600)
  created["status"].as_s.should eq("confirmed")
  created["private"].as_bool.should eq(false)

  # the room and the attendee both see it, and only inside the window asked for
  events = exec(:list_events, room, now, day).get.as_a
  events.size.should eq(1)
  events[0]["title"].as_s.should eq("Standup")
  exec(:list_events, host, now, day).get.as_a.size.should eq(1)
  exec(:list_events, room, now + 7200, day).get.as_a.should be_empty
  exec(:list_events, "other@example.com", now, day).get.as_a.should be_empty

  exec(:get_event, room, id).get.not_nil!["id"].as_s.should eq(id)
  exec(:get_event, room, "missing").get.should eq(nil)

  status[:calendars][room].as_i.should eq(1)
  status[:calendars][host].as_i.should eq(1)

  # an updated event replaces the stored one everywhere it is held
  updated = created.as_h.dup
  updated["title"] = JSON::Any.new("Standup (moved)")
  exec(:update_event, event: updated).get
  exec(:list_events, host, now, day).get.as_a[0]["title"].as_s.should eq("Standup (moved)")

  # declining removes the room's copy and records the response on the host's
  exec(:decline_event, room, id).get
  exec(:list_events, room, now, day).get.as_a.should be_empty
  remaining = exec(:list_events, host, now, day).get.as_a
  remaining.size.should eq(1)
  responses = remaining[0]["attendees"].as_a.map { |a| {a["email"].as_s, a["response_status"]?.try(&.as_s?)} }
  responses.should eq([{host, nil}, {room, "declined"}])

  # deleting removes every copy
  exec(:delete_event, host, id).get
  exec(:list_events, host, now, day).get.as_a.should be_empty

  # the directory comes from settings
  exec(:list_users, "demo").get.as_a.size.should eq(1)
  exec(:list_users, "nobody").get.as_a.should be_empty
  exec(:get_user, "demo.user@example.com").get.not_nil!["name"].as_s.should eq("Demo User")
  exec(:get_user, "nobody@example.com").get.should eq(nil)
end
