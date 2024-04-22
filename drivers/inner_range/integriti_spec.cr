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

  # =====
  # Areas
  # =====
  result = exec(:areas)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <PagedQueryResult>
        <TotalRecords>1</TotalRecords>
        <Page>1</Page>
        <PageSize>1000</PageSize>
        <RowVersion>-1</RowVersion>
        <NextPageUrl>http://20.213.104.2:80/restapi/v2/BasicStatus/Area?Page=2&amp;PageSize=1000&amp;SortProperty=ID&amp;SortOrder=Ascending&amp;</NextPageUrl>
        <Rows>
            <SiteKeyword ID="1">
                <ID>1</ID>
                <Name>Level 1</Name>
                <Site ID="1">
                    <ID>1</ID>
                    <Name>PlaceOS</Name>
                </Site>
            </SiteKeyword>
        </Rows>
      </PagedQueryResult>
    XML
  end

  result.get.should eq([{
    "id"   => 1,
    "name" => "Level 1",
    "site" => {
      "id"   => 1,
      "name" => "PlaceOS",
    },
  }])

  # =====
  # Users
  # =====
  result = exec(:users)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <PagedQueryResult>
          <TotalRecords>12</TotalRecords>
          <Page>1</Page>
          <PageSize>1000</PageSize>
          <RowVersion>-1</RowVersion>
          <NextPageUrl>http://20.213.104.2:80/restapi/v2/BasicStatus/User?Page=2&amp;PageSize=1000&amp;SortProperty=ID&amp;SortOrder=Ascending&amp;</NextPageUrl>
          <Rows>
              <User PartitionID="1" ID="U1">
                  <SiteName>PlaceOS</SiteName>
                  <SiteID>1</SiteID>
                  <ID>281474976710657</ID>
                  <Name>Installer</Name>
                  <Notes></Notes>
                  <Address>U1</Address>
              </User>
              <User PartitionID="0" ID="U2">
                  <SiteName>PlaceOS</SiteName>
                  <SiteID>1</SiteID>
                  <ID>281474976710658</ID>
                  <Name>Master</Name>
                  <Notes></Notes>
                  <Address>U2</Address>
              </User>
              <User PartitionID="2" ID="U3">
                  <SiteName>PlaceOS</SiteName>
                  <SiteID>2</SiteID>
                  <ID>281474976710659</ID>
                  <Name>Card 12</Name>
                  <Notes></Notes>
                  <Address>U3</Address>
                  <cf_EmailAddress>steve@place.tech</cf_EmailAddress>
              </User>
          </Rows>
      </PagedQueryResult>
    XML
  end

  result.get.should eq([
    {
      "id"           => 281474976710657,
      "name"         => "Installer",
      "site_id"      => 1,
      "site_name"    => "PlaceOS",
      "address"      => "U1",
      "partition_id" => 1,
      "email"        => "",
    },
    {
      "id"           => 281474976710658,
      "name"         => "Master",
      "site_id"      => 1,
      "site_name"    => "PlaceOS",
      "address"      => "U2",
      "partition_id" => 0,
      "email"        => "",
    },
    {
      "id"           => 281474976710659,
      "name"         => "Card 12",
      "site_id"      => 2,
      "site_name"    => "PlaceOS",
      "address"      => "U3",
      "partition_id" => 2,
      "email"        => "steve@place.tech",
    },
  ])

  result = exec(:user, 281474976710659)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <User PartitionID="2" ID="U3">
          <SiteName>PlaceOS</SiteName>
          <SiteID>2</SiteID>
          <ID>281474976710659</ID>
          <Name>Card 12</Name>
          <Notes></Notes>
          <Address>U3</Address>
          <cf_EmailAddress>steve@place.tech</cf_EmailAddress>
      </User>
    XML
  end

  result.get.should eq({
    "id"           => 281474976710659,
    "name"         => "Card 12",
    "site_id"      => 2,
    "site_name"    => "PlaceOS",
    "address"      => "U3",
    "partition_id" => 2,
    "email"        => "steve@place.tech",
  })
end
