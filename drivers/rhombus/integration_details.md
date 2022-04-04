# Webhook interaction details

PlaceOS implements the following webhook methods for Rhombus initiated interactions.

A webhook will be create in backoffice on PlaceOS that is unique for each client that will look something like this: https://instance.placeos.com/api/engine/v2/webhook/trig-DHgkU1~p/notify?secret=kfwu5WYc3a1suZ&exec=true&mod=Rhombus&method=request

## Supported methods

These indicate the desired action to be performed, where `Place Webhook` is the unique webhook generated for the client and defined in Rhombus

### POST Place Webhook

Creates a new Rhombus subscription when POSTED with the following body:

```yaml
{
  "webhook": "https://webhooks.rhombussystems.com/external/placeOsWebhook/AAAAAAAAAAAAAA",
  # Random data if signed requests are desirable (optional)
  "secret": "123456"
}
```

responds 201 on success

### DELETE Place Webhook

Removes a Rhombus subscription when DELETED with the following body:

```yaml
{
  "webhook": "https://webhooks.rhombussystems.com/external/placeOsWebhook/AAAAAAAAAAAAAA"
}
```

expects the webhook URL to match an existing subscription
responds 202 on success

### GET Place Webhook

Responds 200 and returns the list of doors in the security system:

```yaml
[
  {
    "door_id": "1234-2342",
    "description": "Lobby Entrance"
  },
  {
    "door_id": "5678-9012"
  }
]
```

### PUT Place Webhook

Attempts to unlock a door when PUT with the following body:

```yaml
{
  "door_id": "5678-9012"
}
```

responds:

* 200 for success
* 403 when failed to unlock for any reason
* 501 if the security system doesn't support remote door unlock

## PlaceOS -> Rhombus

When a door event is detected, the following is sent to each of the Rombus subscriptions

### POST webhooks.rhombussystems

with body

```yaml
{
  "door_id": "123456",
  "timestamp": "2022-04-03T23:59:25Z",
  # signature set if a secret was provided with the initail subscription
  "signature": "HMAC hex digest sha256 signature of timestamp",
  "action": "granted", # or `"denied"` `"tamper"` `"request_to_exit"`
  "card_id": "123456",             # optional
  "user_name": "Steve Place",      # optional
  "user_email": "steve@place.org", # optional
}
```
