require "placeos-driver/spec"

DriverSpecs.mock_driver "MessageMedia::SMS" do
  # select channel
  expect_http_request do |request, response|
    data = request.body.try(&.gets_to_end)
    if data == "type=TT_U8&id=TDU8_CURRENT_CHANNEL&value=0"
      response.status_code = 201
    else
      response.status_code = 400
      response << "badly formatted"
    end
  end

  # request state
  expect_http_request do |request, response|
    response.status_code = 200
    response << %(TT_FLOAT, FLOAT_DATA_0, 0.0000
TT_U32, TDU32_DANTE_LINK_STATE, 0
TT_U32, TDU32_DANTE_SAMPLE_RATE, 0
TT_U32, TDU32_RF_TIMEOUT, 1800000
TT_U32, TDU32_RTC_UNIX_TIME, 981868966
TT_S32, S32_DATA_0, 0
TT_U8, TDU8_VU_METER_VALUE, 0
TT_U8, TDU8_INPUT_GAIN, 10
TT_U8, TDU8_INPUT_SOURCE, 1
TT_U8, TDU8_PRESET, 3
TT_U8, TDU8_HIGH_PASS, 1
TT_U8, TDU8_LOW_PASS, 8
TT_U8, TDU8_COMPRESSION, 1
TT_U8, TDU8_USE_DHCP, 1
TT_U8, TDU8_AUDIO_TX_MODE, 1
TT_U8, TDU8_TTL, 1
TT_U8, TDU8_SECURE_MODE, 0
TT_U8, TDU8_PANEL_LOCK, 0
TT_U8, TDU8_REBOOT, 0
TT_U8, TDU8_RESTORE_DEFAULTS, 0
TT_U8, TDU8_DANTE_PRESENT, 0
TT_U8, TDU8_RF_CHANNEL, 1
TT_U8, TDU8_RF_17_CHANNEL_MODE, 1
TT_U8, TDU8_RF_POWER, 3
TT_S8, TDS8_SERVER_CHANNEL_NO, 0
TT_STRING, TDSTR_SERVER_NAME, Exemplar Room
TT_STRING, TDSTR_CURRENT_IP_ADDR, 138.80.96.228
TT_STRING, TDSTR_STATIC_IP_ADDR, 10.0.0.2
TT_STRING, TDSTR_STATIC_SUBNET_MASK, 255.0.0.0
TT_STRING, TDSTR_STATIC_GATEWAY_ADDR,
TT_STRING, TDSTR_CURRENT_MC_ADDR,
TT_STRING, TDSTR_MULTICAST_ADDR, 0.0.0.0
TT_STRING, TDSTR_JOIN_CODE, 000000
TT_STRING, TDSTR_USER_NAME, cduadmin
TT_STRING, TDSTR_DANTE_DEVICE_NAME,
TT_STRING, TDSTR_DANTE_DEFAULT_NAME,
TT_STRING, TDSTR_DANTE_IP_ADDR,
TT_STRING, TDSTR_DANTE_SUBNET_MASK,
TT_STRING, TDSTR_DANTE_GATEWAY,
TT_STRING, TDSTR_DANTE_MAC_ADDR,
TT_STRING, TDSTR_WEBSERVER_VERSION, 2.2.0
TT_STRING, TDSTR_293_FIRMWARE_VERSION, 2.4.0
TT_STRING, TDSTR_DEVICE_MODEL_NAME, WF_T5
TT_STRING, TDSTR_LAST_LOGGED_ERROR, 981868965 ERR_WEB_404_RESPONSE

)
  end

  sleep 1.second

  # check the status updated
  status["join_code_enabled"]?.should eq false
  status["panel_lock"]?.should eq false
  status["transmit_multicast"]?.should eq true
  status["reboot"]?.should eq 0
  status["rf_power"]?.should eq 3
  status["input_source"]?.should eq "AnalogLineIn"
  status["preset"]?.should eq "HearingAssist"

  # check the various methods work
  retval = exec(:reboot)
  expect_http_request do |request, response|
    data = request.body.try(&.gets_to_end)
    if data == "type=TT_U8&id=TDU8_CURRENT_CHANNEL&value=0&type=TT_U8&id=TDU8_REBOOT&value=1"
      response.status_code = 201
    else
      response.status_code = 400
      response << "badly formatted"
    end
  end
  retval.get.should eq(1)
end
