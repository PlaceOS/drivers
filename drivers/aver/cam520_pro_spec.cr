require "placeos-driver/spec"
require "./cam520_pro_models"

DriverSpecs.mock_driver "Aver::Cam520Pro" do
  # ====================
  # should send an authentication request
  # ====================
  token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpYXQiOjE2Njc3ODE0OTR9.blGZUSAekKJVi4VoOAEg9fARCOhyIMNiu_37L3Jv070"
  expect_http_request do |request, response|
    io = request.body
    if io
      data = io.gets_to_end
      request = JSON.parse(data)
      if request["name"] == "admin" && request["password"] == "Aver"
        response.status_code = 200
        response << {
          code: 200,
          msg:  "ok",
          data: {
            token: token,
          },
        }.to_json
      else
        response.status_code = 401
      end
    else
      raise "expected request to include dialing details #{request.inspect}"
    end
  end

  should_send "token:#{token}"

  # ======================
  # query state on connect
  # ======================

  # query pan?
  expect_http_request do |request, response|
    data = request.body.not_nil!.gets_to_end
    request = JSON.parse(data)
    if request["method"] == "Get" && request["option"] == "ptz_p_s"
      response.status_code = 200
      response << {
        code: 200,
        msg:  "ok",
        data: 200,
      }.to_json
    else
      response.status_code = 400
    end
  end

  # query tilt?
  expect_http_request do |request, response|
    data = request.body.not_nil!.gets_to_end
    request = JSON.parse(data)
    if request["method"] == "Get" && request["option"] == "ptz_t_s"
      response.status_code = 200
      response << {
        code: 200,
        msg:  "ok",
        data: 100,
      }.to_json
    else
      response.status_code = 400
    end
  end

  # query zoom?
  expect_http_request do |request, response|
    data = request.body.not_nil!.gets_to_end
    request = JSON.parse(data)
    if request["method"] == "Get" && request["option"] == "ptz_z_s"
      response.status_code = 200
      response << {
        code: 200,
        msg:  "ok",
        data: 0,
      }.to_json
    else
      response.status_code = 400
    end
  end

  sleep 0.2

  status[:zoom].should eq(0.0)
  exec(:pan_pos).get.should eq(200)
  exec(:tilt_pos).get.should eq(100)

  # ====================
  # test zoom value parsing
  # ====================
  transmit({
    event: "option",
    data:  {
      option: "ptz_z_s",
      value:  "28448",
    },
  }.to_json)

  sleep 0.2

  status[:zoom].should eq(100.0)

  # ====================
  # check zoom interface
  # ====================
  resp = exec(:zoom_to, 0.0)
  expect_http_request do |request, response|
    data = request.body.not_nil!.gets_to_end
    request = JSON.parse(data)
    if request["option"] == "ptz_z" && request["value"] == 0
      response.status_code = 200
      response << {
        code: 200,
        msg:  "ok",
        data: nil,
      }.to_json
    else
      response.status_code = 400
    end
  end
  resp.get

  transmit({
    event: "option",
    data:  {
      option: "ptz_z_s",
      value:  "0",
    },
  }.to_json)

  sleep 0.2

  status[:zoom].should eq(0.0)

  # ======================
  # check camera interface
  # ======================
  resp = exec(:joystick, 80.0, 10.0)
  # Stop tilt
  expect_http_request do |request, response|
    data = request.body.not_nil!.gets_to_end
    request = JSON.parse(data)
    if request["axis"] == 1 && request["cmd"] == 2
      response.status_code = 200
      response << {
        code: 200,
        msg:  "ok",
        data: nil,
      }.to_json
    else
      raise "stop move failed in joystick request"
    end
  end
  # Move pan
  expect_http_request do |request, response|
    data = request.body.not_nil!.gets_to_end
    request = JSON.parse(data)
    if request["axis"] == 0 && request["cmd"] == 1
      response.status_code = 200
      response << {
        code: 200,
        msg:  "ok",
        data: nil,
      }.to_json
    else
      response.status_code = 400
    end
  end
  resp.get
end
