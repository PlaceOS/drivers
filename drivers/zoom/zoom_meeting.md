# Zoom Meeting Driver overview

## Meeting Joining

Related state

```crystal
# Int64 | Nil - is the start time of the current meeting with a zoom link
meeting_in_progress

# Int64 | Nil - timestamp of the last meeting joined
# if different from meeting_in_progress then make sure to show buttons to `join_meeting`
meeting_joined
```

related functions

* `Zoom.join_meeting(start_time : Int64? = nil)` - start_time is optional, if not specified will use the `meeting_in_progress` status value
  * if this function returns a hash, the touch panel can use it to join the meeting for additional controls via the JS SDK
  * if this function returns nil and `meeting_joined` updated to match `meeting_in_progress` or the start_time you passed in, then a 3rd party meeting is in progress (teams or meet) - but the touch panel doesn't need to join as it won't be able to control the meeting.
* `Zoom.leave_meeting` - leaves the meeting, without ending the meeting
* `Zoom.end_meeting` - ends the meeting for everyone
  * both these set `meeting_joined` to `nil`

## Meeting Recording

```crystal
# "stop" | "start" | "pause" - the current state of cloud recordings
# if equal to "pause" then you can "resume" the recording
recording
```

related functions

* `Zoom.recording(command : Recording) : Recording` - command is one of "stop", "start" or "pause"

## Meeting Controls

Status for binding

```crystal
# Bool - is the local mic audio muted
mic_mute

# Bool - is the local camera video muted
camera_mute

# Bool - are we sharing content locally
share_content

# Int32 - the room volume, 0-100
volume
```

related functions

* `Zoom.mic_mute(state : Bool = true) : Bool`
* `Zoom.camera_mute(state : Bool = true) : Bool`
* `Zoom.share_content(state : Bool = true) : Bool`
* `Zoom.volume(level : Int32) : Int32`

## Adding additional people to the current call

* `Zoom.call_phone(invitee_name : String, phone_number : String)`
* `Zoom.invite_contacts(emails : String | Array(String))`
