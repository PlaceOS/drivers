# Auto Release Readme

Docs on how to configure the Auto Release driver.
This driver automatically releases bookings when users have indicated they are not on-site (work from home or away on leave) and haven't checked in to their booking.

* The driver monitors bookings for configured resource types (e.g., desks)
* Checks user work location preferences and overrides against release locations
* Sends notification emails to users before automatically releasing their bookings
* Releases bookings after a configurable time period if users don't confirm attendance


## Requirements

Requires the following drivers in the system:

* StaffAPI - for querying bookings and user preferences
* Mailer - for sending notification emails, this also will be where the templates are configured

**CRITICAL:** The building zone must have its timezone configured. The Auto Release driver always operates using the building's timezone for all time-based calculations and evaluations.


## Auto Release Configuration

```yaml
  # How do we want dates to be formatted in the email template
  date_time_format:  "%c"
  time_format:       "%l:%M%p" 
  date_format:       "%A, %-d %B"

  # Cron schedule for sending notification emails (default every 5 minutes)
  email_schedule:    "*/5 * * * *"
  
  # Email template name to use for notifications
  email_template:    "auto_release"
  
  # Use unique templates per booking type (e.g. auto_release_desk, auto_release_parking)
  unique_templates:  false

  # Hours ahead to check for bookings that may need to be released
  time_window_hours: 4

  # User work locations that trigger auto-release
  # Available locations: wfh (Work From Home), aol (Away on Leave), wfo (Work From Office)
  release_locations: ["wfh", "aol"]

  # Skip bookings created after their start time
  skip_created_after_start: true
  
  # Skip bookings created on the same day as the booking
  skip_same_day: false
  
  # Skip all-day bookings from auto-release
  skip_all_day: false

  # Cache timeout for asset name lookups (in seconds)
  asset_cache_timeout: 3600
```

## Zone Configuration Requirements

**CRITICAL:** The `auto_release` configuration must be set on the building zone as an **Unencrypted** setting. This is absolutely required for both the driver to function properly and for the Concierge UI to manage auto-release settings.

**STRONGLY RECOMMENDED:** Use the Concierge UI to configure auto-release settings. The UI provides a user-friendly interface for managing all auto-release configuration options and ensures proper validation of settings.

The building zone configuration should look like this:

```yaml
# This must be configured as Unencrypted on the building zone
auto_release:
  # Time before booking start to send notification email (minutes)
  # Can be negative to send notifications after booking start
  time_before: 10
  
  # Time after booking start to automatically release booking (minutes)  
  time_after: 15
  
  # Resource types to monitor for auto-release
  resources: ["desk", "parking"]
  
  # Default work preferences for users without configured preferences
  default_work_preferences: []
  
  # Release bookings outside of configured work hours
  # Set to true for 24/7 automatic release capability
  release_outside_hours: false
  
  # Start time for all-day bookings (24-hour format, e.g. 8.0 = 8:00 AM)
  # See detailed explanation below
  all_day_start: 8.0

  # Per-resource timing overrides (optional)
  # desk_time_before: 5    # Override time_before for desk bookings  
  # desk_time_after: 20    # Override time_after for desk bookings
```

### Important Configuration Notes

- **Negative time_before values**: When `time_before` is negative, notification emails are sent AFTER the booking has started. For example, `time_before: -5` means emails are sent 5 minutes after the booking start time.

- **24/7 Release**: For buildings that need automatic release at any time of day, set `release_outside_hours: true`. This is particularly useful for flexible workspaces.

- **Resource-specific timing**: You can override `time_before` and `time_after` for specific resource types by adding `{resource}_time_before` and `{resource}_time_after` settings.

- **All-day booking start time (`all_day_start`)**: All-day bookings technically start at midnight (00:00), but checking work preferences against midnight doesn't make practical sense. The `all_day_start` setting defines a virtual "work day start time" that is used ONLY for evaluating whether an all-day booking should be released based on the user's work location preferences.

  For example, if `all_day_start: 8.0` (8:00 AM) and a user has work preferences indicating they work from home from 8:00 AM to 5:00 PM, the system will check the user's 8:00 AM work location preference to determine if the all-day booking should be released. This makes the evaluation meaningful in the context of a normal work day rather than checking against midnight when most people wouldn't be expected to be at work anyway.

  The actual booking times remain unchanged - this setting only affects the work preference evaluation logic for all-day bookings.


## Default Work Preferences Configuration

The `default_work_preferences` setting provides fallback work location preferences for users who haven't configured their preferences in the Workplace app. This is particularly useful during initial rollout or for users who haven't yet set up their work schedules.

**RECOMMENDED:** Use the Concierge UI to configure default work preferences. The UI provides validation and makes it easier to set up complex schedules without manually writing YAML.

```yaml
auto_release:
  default_work_preferences:
    # Monday (day 1) - User works from home 9 AM to 5 PM
    - day_of_week: 1
      blocks:
        - start_time: 9.0    # 9:00 AM
          end_time: 17.0     # 5:00 PM  
          location: "wfh"    # Work From Home
    
    # Tuesday (day 2) - User works from office 8:30 AM to 4:30 PM
    - day_of_week: 2
      blocks:
        - start_time: 8.5    # 8:30 AM
          end_time: 16.5     # 4:30 PM
          location: "wfo"    # Work From Office
    
    # Wednesday (day 3) - Split day: morning WFH, afternoon WFO
    - day_of_week: 3
      blocks:
        - start_time: 9.0    # 9:00 AM
          end_time: 13.0     # 1:00 PM
          location: "wfh"
        - start_time: 14.0   # 2:00 PM  
          end_time: 18.0     # 6:00 PM
          location: "wfo"
    
    # Thursday (day 4) - Away on leave all day
    - day_of_week: 4
      blocks:
        - start_time: 0.0    # All day
          end_time: 24.0
          location: "aol"    # Away on Leave
    
    # Friday through Sunday can be omitted if no default schedule needed
```

### Day of Week Values
- `0` = Sunday
- `1` = Monday  
- `2` = Tuesday
- `3` = Wednesday
- `4` = Thursday
- `5` = Friday
- `6` = Saturday

### Time Format
Times are specified in 24-hour format as decimal numbers:
- `9.0` = 9:00 AM
- `9.5` = 9:30 AM  
- `17.0` = 5:00 PM
- `17.75` = 5:45 PM

### Location Values
- `"wfh"` = Work From Home (triggers auto-release)
- `"wfo"` = Work From Office (prevents auto-release)
- `"aol"` = Away on Leave (triggers auto-release)

**Note**: These defaults are only used for users who haven't set their own preferences in the Workplace app. Once a user configures their preferences, these defaults are ignored for that user.

**Important**: If `release_outside_hours: true` is set, configuring `default_work_preferences` may be unnecessary. When `release_outside_hours` is enabled, any booking that doesn't match the user's configured work preferences (or default preferences) will automatically be flagged for release anyway. This makes `default_work_preferences` primarily useful when you want more granular control over release timing rather than blanket 24/7 release behavior.


## Template Configuration on Mailer

The driver expects an email template for notifying users about pending releases:

* `auto_release` (default template name, configurable via email_template setting)
* `auto_release_desk` (if unique_templates is true and desk is a configured resource)
* `auto_release_parking` (if unique_templates is true and parking is a configured resource)

```yaml
email_templates:
  bookings:
    auto_release:
      subject: "Your booking may be released - %{asset_name} on %{start_date}"
      html: >
        <html><body>
        <p>Hello %{user_name},</p>
        <p>Your booking for %{asset_name} on %{start_datetime} may be automatically released 
        because your work location preferences indicate you are working from home or away on leave.</p>
        
        <p>If you plan to use this booking, please check in when you arrive.</p>
        
        <p>Booking Details:</p>
        <ul>
          <li>Resource: %{asset_name}</li>
          <li>Date: %{start_date}</li>
          <li>Time: %{start_time} - %{end_time}</li>
          <li>Reason: %{reason}</li>
        </ul>
        </body></html>
```

## Template Variables

The following variables are available for use in email templates:

* `booking_id` - Unique identifier for the booking that may be released
* `booking_start` - Unix timestamp of when the booking begins  
* `booking_end` - Unix timestamp of when the booking ends
* `start_time` - Formatted start time (e.g., "9:00AM")
* `start_date` - Formatted start date (e.g., "Monday, 15 January") 
* `start_datetime` - Formatted start date and time (e.g., "Mon Jan 15 09:00:00 2024")
* `end_time` - Formatted end time (e.g., "5:00PM")
* `end_date` - Formatted end date (e.g., "Monday, 15 January")
* `end_datetime` - Formatted end date and time (e.g., "Mon Jan 15 17:00:00 2024")
* `asset_id` - Identifier of the booked resource
* `asset_name` - Name of the booked resource
* `user_id` - Identifier of the person who has the booking
* `user_email` - Email address of the person who has the booking  
* `user_name` - Full name of the person who has the booking
* `reason` - Title or purpose of the booking
* `approver_name` - Name of the person who approved the booking
* `approver_email` - Email of the person who approved the booking
* `booked_by_name` - Name of the person who made the booking
* `booked_by_email` - Email of the person who made the booking


## How It Works

1. **Monitoring**: The driver periodically checks for bookings in the configured time window that haven't been checked in
2. **User Preferences**: For each booking, it retrieves the user's work location preferences and any daily overrides
3. **Location Matching**: If the user's work location preference matches a release location (e.g., "wfh", "aol") during the booking time, the booking is flagged for potential release
4. **Notification**: An email is sent to the user before the booking start time (configurable via `time_before`)
5. **Release**: If the user doesn't check in after the booking start time, the booking is automatically rejected after the configured delay (`time_after`)

The driver respects user work preferences and overrides, only releasing bookings when users have indicated they will be working from home or away on leave during the booking period.


## User Work Preferences

Users can set their work location preferences through the **Workplace app**. These preferences are stored in the Staff API and include:

* **Work Preferences**: Regular weekly schedule indicating work location by day and time
* **Work Overrides**: Specific date overrides for the regular schedule (e.g., working from office on a normally WFH day)

The driver checks both preferences and overrides to determine if a user will be on-site for their booking. Users should ensure their work location preferences are kept up-to-date in the Workplace app to avoid unnecessary booking releases.


## Debugging and Monitoring

The driver provides a `explain_state` function that returns detailed information about:

* Current pending bookings and why they are or aren't flagged for release
* Bookings that have been emailed
* Bookings that have been released
* Detailed reasoning for each booking's status

This can be helpful for troubleshooting why certain bookings are or aren't being processed.