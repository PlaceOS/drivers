require "json"
require "uuid"

module Relaxx
  SUCCESS = {
    Successful: true,
    Cancelled:  false,
    ResultText: "",
    ResultCode: 0,
  }

  def self.frame(data)
    "\x02#{data.to_json}\x03"
  end

  def self.parse(raw_data)
    JSON.parse(String.new(raw_data)[1..-2])
  end
end

DriverSpecs.mock_driver "Gantner::Relaxx::ProtocolJSON" do
  # Should send an auth A request
  data = Relaxx.parse(expect_send)
  data["Caption"].as_s.should eq("AuthenticationRequestA")
  id = data["Id"].as_s

  # Respond with auth A response
  transmit Relaxx.frame({
    Caption:              "AuthenticationResponseA",
    Result:               Relaxx::SUCCESS,
    Id:                   UUID.random.to_s.upcase,
    RequestId:            id,
    AuthenticationString: "wglgJg4kP8DHO+2+N6L8Hsu6mp3LSoe3/gIxDlZgu60=",
    LoggedIn:             false,
    IsLoginCommand:       true,
    IsNotification:       false,
    IsResponse:           true,
    CustomTimeout:        0,
    CompressContent:      false,
  })

  # Should send an auth B request
  data = Relaxx.parse(expect_send)
  data["Caption"].as_s.should eq("AuthenticationRequestB")
  id = data["Id"].as_s

  # password should be decrypted
  data["AuthenticationString"].as_s.should eq("499520882")

  # Respond with auth B response
  transmit Relaxx.frame({
    Caption:         "AuthenticationResponseB",
    Result:          Relaxx::SUCCESS,
    Id:              UUID.random.to_s.upcase,
    RequestId:       id,
    LoggedIn:        true,
    IsLoginCommand:  true,
    IsNotification:  false,
    IsResponse:      true,
    CustomTimeout:   0,
    CompressContent: false,
  })

  # Expect a locker state query
  data = Relaxx.parse(expect_send)
  data["Caption"].as_s.should eq("GetLockersRequest")
  id = data["Id"].as_s

  locker_id1 = UUID.random.to_s
  locker_id2 = UUID.random.to_s

  transmit Relaxx.frame({
    Caption:        "GetLockersResponse",
    Result:         Relaxx::SUCCESS,
    Id:             UUID.random.to_s.upcase,
    RequestId:      id,
    IsNotification: false,
    IsResponse:     true,
    Lockers:        [{
      RecordId:        locker_id1,
      LockerGroupId:   UUID.random.to_s,
      LockerGroupName: "Example Group",
      Number:          "1",
      Address:         21,
      State:           2,
      LockerMode:      3,
      IsFreeLocker:    false,
      IsDeleted:       false,
      IsExisting:      true,
      LastClosedTime:  "",
      CardUIDInUse:    "",
    }, {
      RecordId:        locker_id2,
      LockerGroupId:   UUID.random.to_s,
      LockerGroupName: "Example Group",
      Number:          "2",
      Address:         21,
      State:           3,
      LockerMode:      3,
      IsFreeLocker:    false,
      IsDeleted:       false,
      IsExisting:      true,
      LastClosedTime:  "",
      CardUIDInUse:    "12345",
    }],
  })

  # send a keep alive request
  exec(:keep_alive)
  data = Relaxx.parse(expect_send)
  data["Caption"].as_s.should eq("KeepAliveRequest")
  id = data["Id"].as_s

  transmit Relaxx.frame({
    Caption:         "KeepAliveResponse",
    Result:          Relaxx::SUCCESS,
    Id:              UUID.random.to_s.upcase,
    RequestId:       id,
    LoggedIn:        true,
    IsLoginCommand:  false,
    IsNotification:  false,
    IsResponse:      true,
    CustomTimeout:   0,
    CompressContent: false,
  })

  status[:authenticated].should eq(true)
  status[:locker_ids].should eq([locker_id1, locker_id2])
  status[:lockers_in_use].should eq([locker_id2])
  status["locker_#{locker_id2}"].should eq("12345")
end
