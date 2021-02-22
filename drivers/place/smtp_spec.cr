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
end
