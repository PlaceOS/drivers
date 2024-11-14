require "placeos-driver/spec"

DriverSpecs.mock_driver "Place::Demo::TestSSH" do
  resp = exec(:run, "ls")
  should_send "ls\n"
  responds "bin  docker-compose.yml  examples  lib\n"
  resp.get.should eq "bin  docker-compose.yml  examples  lib\n"
end
