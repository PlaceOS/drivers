require "placeos-driver/spec"

DriverSpecs.mock_driver "InnerRange::Integriti" do
  # ===========
  # SYSTEM INFO
  # ===========
  result = exec(:system_info)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
    <SystemInfo xmlns:i="http://www.w3.org/2001/XMLSchema-instance" xmlns="http://schemas.datacontract.org/2004/07/IR.Integriti.ServerCommon.Communication.RestApi.Models">
      <ProductEdition>Integriti Professional Edition</ProductEdition>
      <ProductVersion>23.1.1.21454</ProductVersion>
      <ProtocolVersion>3</ProtocolVersion>
    </SystemInfo>
    XML
  end

  result.get.should eq({
    "edition"  => "Integriti Professional Edition",
    "version"  => "23.1.1.21454",
    "protocol" => "3",
  })

  # ===========
  # API VERSION
  # ===========
  result = exec(:api_version)

  expect_http_request do |request, response|
    response.status_code = 200
    response << %(<ApiVersion>http://20.213.104.2:80/restapi/ApiVersion/v2</ApiVersion>)
  end

  result.get.should eq "v2"
end
