require "email"

DriverSpecs.mock_driver "Place::Smtp" do
  settings({
    sender:   "support@place.tech",
    host:     ENV["PLACE_SMTP_HOST"]? || "smtp.host",
    port:     ENV["PLACE_SMTP_PORT"]?.try(&.to_i) || 587,
    username: ENV["PLACE_SMTP_USER"]? || "", # Username/Password for SMTP servers with basic authorization
    password: ENV["PLACE_SMTP_PASS"]? || "",
  })

  response = exec(
    :send_mail,
    subject: "Test Email",
    to: ENV["PLACE_TEST_EMAIL"]? || "support@place.tech",
    message_plaintext: "Hello!",
  ).get

  response.should be_true
end
