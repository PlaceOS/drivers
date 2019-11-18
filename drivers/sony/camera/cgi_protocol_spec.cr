EngineSpec.mock_driver "Floorsense::Desks" do
  # Send the request
  retval = exec(:query_status)

  # We should request a new token from Floorsense
  expect_http_request do |request, response|
    response.status_code = 200
    response.output.puts %(AbsolutePTZF=15400,fd578,0000,cb5a&PanMovementRange=eac00,15400&PanPanoramaRange=de00,2200&PanTiltMaxVelocity=24&PtzInstance=1&TiltMovementRange=fc400,b400&TiltPanoramaRange=fc00,1200&ZoomMaxVelocity=8&ZoomMovementRange=0000,4000,7ac0&PtzfStatus=idle,idle,idle,idle&AbsoluteZoom=609)
  end

  # What the function should return (for use in making further requests)
  retval.get.not_nil!["AbsoluteZoom"].should eq("609")
  status[:pan].should eq(87040)
end
