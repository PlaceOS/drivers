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
    "protocol" => 3,
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

  # =====
  # Sites
  # =====
  result = exec(:sites)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <PagedQueryResult>
        <TotalRecords>1</TotalRecords>
        <Page>1</Page>
        <PageSize>1000</PageSize>
        <RowVersion>-1</RowVersion>
        <NextPageUrl>http://20.213.104.2:80/restapi/v2/BasicStatus/SiteKeyword?Page=2&amp;PageSize=1000&amp;SortProperty=ID&amp;SortOrder=Ascending&amp;</NextPageUrl>
        <Rows>
            <SiteKeyword ID="1">
                <ID>1</ID>
                <Name>PlaceOS</Name>
            </SiteKeyword>
        </Rows>
      </PagedQueryResult>
    XML
  end

  result.get.should eq([{
    "id"   => 1,
    "name" => "PlaceOS",
  }])
end
