DriverSpecs.mock_driver "Extron::Matrix" do
  switch = exec :switch, input: 1, output: 2
  should_send "1*2!"
  responds "Out2 In1 All\r\n"

  switch_to = exec :switch_to, input: 1
  should_send "1*!"
  responds "In1 All\r\n"

  switch_map = exec :switch_map, { 1 => [2, 3, 4] }
  should_send "\e+Q1*2!1*3!1*4!\r"
  responds "Qik\r\n"
end
