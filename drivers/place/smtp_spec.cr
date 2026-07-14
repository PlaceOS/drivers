require "placeos-driver/spec"
require "email"

# for local testing use: http://nilhcem.com/FakeSMTP/download.html

DriverSpecs.mock_driver "Place::Smtp" do
  settings({
    sender:   "support@place.tech",
    host:     ENV["PLACE_SMTP_HOST"]? || "localhost",
    port:     ENV["PLACE_SMTP_PORT"]?.try(&.to_i) || 25,
    username: ENV["PLACE_SMTP_USER"]? || "", # Username/Password for SMTP servers with basic authorization
    password: ENV["PLACE_SMTP_PASS"]? || "",
    tls_mode: ENV["PLACE_SMTP_MODE"]? || "none",
    reply_to: "noreply@place.tech",

    email_templates: {visitor: {checkin: {
      subject: "%{name} has arrived",
      text:    "for your meeting at %{time}",
    }}},
  })

  response = exec(
    :send_mail,
    subject: "Test Email",
    to: ENV["PLACE_TEST_EMAIL"]? || "support@place.tech",
    message_plaintext: "Hello!",
  ).get

  response.should be_true

  response = exec(
    :send_template,
    to: "steve@place.tech",
    template: {"visitor", "checkin"},
    args: {
      name: "Bob",
      time: "1:30pm",
    }
  ).get

  response.should be_true

  # a reply_to configured on the driver overrides any reply_to passed in.
  # NOTE: the spec framework only exposes the send result, not the message
  # headers, so this exercises the override path and confirms the send still
  # succeeds with both a configured and a passed-in reply_to present.
  response = exec(
    :send_mail,
    subject: "Reply-To Test",
    to: ENV["PLACE_TEST_EMAIL"]? || "support@place.tech",
    message_plaintext: "Hello!",
    reply_to: "passed-in@place.tech",
  ).get

  response.should be_true
end
