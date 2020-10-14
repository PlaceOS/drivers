DriverSpecs.mock_driver "Planar::ClarityMatrix" do
  # If WallNet receives an empty line (no command text, followed by a CR or LF), it responds with “# Clarity ASCII protocol server ready (TCP).\r\n”
  
  it "should run a spec" do
    "hello".should eq("hell")
  end
end
