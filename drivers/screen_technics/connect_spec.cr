EngineSpec.mock_driver "ScreenTechnics::Connect" do
  # On connect it queries the state of all screens
  should_send("1, 17, 32\r\n")
  responds("101, 1, 17, 1\r\n")

  status[:position0].should eq("Down")
  status[:moving0].should eq(true)
  status[:screen0].should eq("moving_bottom")

  # Screen Technics requires a large delay between requests
  # The timeout is because this execute won't occur until after a delay
  exec(:query_state, index: 1) do |ret_val|
    should_send("1, 18, 32\r\n", timeout: 1.second)
    responds("101, 1, 18, 6\r\n")

    # Wait for the execute return value
    ret_val.get

    status[:position1].should eq("Up")
    status[:moving1].should eq(false)
    status[:screen1].should eq("at_top")
  end

  # ===================
  # Test emergency stop
  # ===================
  exec(:move, "Down", 2) do |ret_val|
    # A call to down involves a
    # * stop command
    # * down command
    # * status request
    sleep 1.second
    should_send("36, 19\r\n", timeout: 1.second)
    responds("136, 1, 19\r\n")

    # --> Wait for the down command
    should_send("33, 19\r\n", timeout: 1.second)

    # Execute the emergency stop and request another down request
    exec(:stop, index: 2, emergency: true) do |response|
      exec(:move, "Down", 2)
      sleep 500.milliseconds

      # --> respond to the down command
      responds("133, 1, 19, 1\r\n")

      # Should receive emergency stop command
      should_send("36, 19\r\n", timeout: 1.second)
      responds("136, 1, 19\r\n")
      status[:moving2].should eq(false)
      response.get
    end

    # Original down command should have failed
    expect_raises(ACAEngine::Driver::RemoteException, "queue cleared (Abort)") do
      ret_val.get
    end

    puts "(timeout below expected)"

    # Ensure second down command is not sent
    expect_raises(Channel::ClosedError) do
      should_send("33, 17\r\n", timeout: 1.second)
    end
  end
end
