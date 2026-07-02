# Booking Approval Workflows Readme

Drives manager approval workflows for asset bookings (defaults to desks) and sends
the associated notification emails: approvals, rejections, cancellations, manager
approval requests/reminders/escalations, and check-in reminders.

## Requirements

Requires the following drivers in the system:

* StaffAPI - for querying bookings and updating booking state
* Mailer - for sending emails (and where the templates are configured)
* Calendar - for looking up a user's manager

## Configuration

```yaml
  booking_type:    "desk"
  notify_managers: false
  remind_after:    24   # hours before reminding a manager to approve
  escalate_after:  48   # hours before escalating to the manager's manager

  # zone_id => approval configuration
  approval_type: {
    zone_id1: {
      approval:      "manager_approval",
      name:          "Sydney Building 1",
      support_email: "support@place.com",
      attachments:   null,
    },
  }
```

## Reply-To

Approval workflow emails set a `Reply-To` header so replies reach a useful person
rather than the no-reply sender address. By default the reply-to is the **booking
creator** (`booked_by_email`) -- including emails sent to managers. This requires
no configuration.

This default can be overridden per-template (a `reply_to` field on the template
metadata), tenant-wide (the `reply_to` setting on the Template Mailer), or for all
mail (the `reply_to` setting on the SMTP Mailer). See the Template Mailer readme
for the full precedence cascade.
