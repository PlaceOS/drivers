require "openssl"
require "placeos-driver/driver-specs/runner"

DriverSpecs.mock_driver "Cisco::Meraki::CaptivePortal" do
  date = Time.unix(1599477274).in(Time::Location.load("Australia/Sydney")).to_s("%Y%m%d")
  hexdigest = OpenSSL::Digest.new("SHA256").update("guest@email.com-#{date}-anything really").final.hexstring

  # Check the hex codes match
  retval = exec(:generate_guest_data, "guest@email.com", 1599477274, "Australia/Sydney")
  retval.get.should eq hexdigest

  # check it matches on of the codes
  codes = hexdigest.scan(/.{4}/).map { |code| code[0] }
  retval = exec(:generate_guest_token, "guest@email.com", 1599477274, "Australia/Sydney")
  codes.includes?(retval.get.not_nil!.as_s).should eq true
end
