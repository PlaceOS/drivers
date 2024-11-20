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
                  <PrimaryPermissionGroup>
                    <Ref Type="PermissionGroup" PartitionID="0" ID="QG4" />
                  </PrimaryPermissionGroup>
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
    },
    {
      "id"           => 281474976710658,
      "name"         => "Master",
      "site_id"      => 1,
      "site_name"    => "PlaceOS",
      "address"      => "U2",
      "partition_id" => 0,
    },
    {
      "id"                       => 281474976710659,
      "name"                     => "Card 12",
      "site_id"                  => 2,
      "site_name"                => "PlaceOS",
      "address"                  => "U3",
      "partition_id"             => 2,
      "email"                    => "steve@place.tech",
      "primary_permission_group" => {
        "partition_id" => 0,
        "address"      => "QG4",
      },
    },
  ])

  result = exec(:user, 281474976710659)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <User PartitionID="2" ID="U3">
          <Site>
            <Ref Type="SiteKeyword" ID="2" Name="PlaceOS"/>
          </Site>
          <ID>281474976710659</ID>
          <Name>Card 12</Name>
          <Notes></Notes>
          <Address>U3</Address>
          <cf_EmailAddress>steve@place.tech</cf_EmailAddress>
          <PrimaryPermissionGroup>
            <Ref Type="PermissionGroup" PartitionID="0" ID="QG4"/>
          </PrimaryPermissionGroup>
      </User>
    XML
  end

  result.get.should eq({
    "id"                       => 281474976710659,
    "name"                     => "Card 12",
    "site"                     => {"id" => 2, "name" => "PlaceOS"},
    "address"                  => "U3",
    "partition_id"             => 2,
    "email"                    => "steve@place.tech",
    "primary_permission_group" => {"partition_id" => 0, "address" => "QG4"},
  })

  # =====
  # Cards
  # =====
  result = exec(:cards)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <PagedQueryResult>
        <TotalRecords>10</TotalRecords>
        <Page>1</Page>
        <PageSize>1000</PageSize>
        <RowVersion>-1</RowVersion>
        <NextPageUrl>http://20.213.104.2:80/restapi/v2/VirtualCardBadge/Card?Page=2&amp;PageSize=1000&amp;SortProperty=ID&amp;SortOrder=Ascending&amp;AdditionalProperties=ID,Name,CardNumberNumeric,User,CardNumber,CardSerialNumber,State,Site,ExpiryDateTime,StartDateTime,LastUsed,CardType,CloudCredentialType,CloudCredentialPoolId,ManagedByActiveDirectory&amp;</NextPageUrl>
        <Rows>
          <Card ID="c1fc4c28-0c1c-4573-a9cf-0025dbf6c8f7">
              <ID>c1fc4c28-0c1c-4573-a9cf-0025dbf6c8f7</ID>
              <Name>19</Name>
              <Notes></Notes>
              <Site>
                  <Ref Type="SiteKeyword" ID="1" Name="PlaceOS"/>
              </Site>
              <User>
                  <Ref Type="User" PartitionID="0" ID="U10"/>
              </User>
              <LastUsed>2024-04-11T00:49:35.6588387+12:00</LastUsed>
              <State>Active</State>
              <ManagedByActiveDirectory>False</ManagedByActiveDirectory>
              <StartDateTime>0001-01-01T00:00:00.0000000+00:00</StartDateTime>
              <ExpiryDateTime>0001-01-01T00:00:00.0000000+00:00</ExpiryDateTime>
              <CardNumber>19</CardNumber>
              <CardNumberNumeric>19</CardNumberNumeric>
              <CloudCredentialType>None</CloudCredentialType>
          </Card>
        </Rows>
      </PagedQueryResult>
    XML
  end

  result.get.should eq([
    {
      "id"                    => "c1fc4c28-0c1c-4573-a9cf-0025dbf6c8f7",
      "name"                  => "19",
      "card_number_numeric"   => 19,
      "card_number"           => "19",
      "state"                 => "Active",
      "expiry"                => "0001-01-01T00:00:00.0000000+00:00",
      "valid_from"            => "0001-01-01T00:00:00.0000000+00:00",
      "last_used"             => "2024-04-11T00:49:35.6588387+12:00",
      "cloud_credential_type" => "None",
      "active_directory"      => false,
      "site"                  => {
        "id"   => 1,
        "name" => "PlaceOS",
      },
      "user" => {
        "address"      => "U10",
        "partition_id" => 0,
      },
    },
  ])

  # =================
  # Permission Groups
  # =================
  result = exec(:permission_groups)

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <PagedQueryResult>
          <TotalRecords>3</TotalRecords>
          <Page>1</Page>
          <PageSize>25</PageSize>
          <RowVersion>-1</RowVersion>
          <NextPageUrl>http://20.213.104.2:80/restapi/v2/User/PermissionGroup?Page=2&amp;PageSize=25&amp;SortProperty=ID&amp;SortOrder=Ascending&amp;</NextPageUrl>
          <Rows>
              <PermissionGroup PartitionID="0" ID="QG1">
                  <SiteName>PlaceOS</SiteName>
                  <SiteID>1</SiteID>
                  <ID>1970324836974593</ID>
                  <Name>Manager</Name>
                  <Notes></Notes>
                  <Address>QG1</Address>
              </PermissionGroup>
          </Rows>
      </PagedQueryResult>
    XML
  end

  result.get.should eq([
    {
      "partition_id" => 0,
      "site_name"    => "PlaceOS",
      "site_id"      => 1,
      "id"           => 1970324836974593,
      "name"         => "Manager",
      "address"      => "QG1",
    },
  ])

  result = exec(:modify_user_permissions, "U54", "QG4")

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <AddToCollectionResult>
        <Message>UserPermission with ID: 61a1c248-d62d-4485-a3e9-815918afac71 added to Permissions for User with ID U54</Message>
        <NumberOfItemsAdded>1</NumberOfItemsAdded>
      </AddToCollectionResult>
    XML
  end

  result.get.should eq({
    "message"  => "UserPermission with ID: 61a1c248-d62d-4485-a3e9-815918afac71 added to Permissions for User with ID U54",
    "modified" => 1,
  })

  result = exec(:revoke_guest_access, {user_id: "U56", permission_id: "9ee6dfdd-9c01-4b67-b9f2-316ca7c9fdc5", card_hex: ""})

  expect_http_request do |request, response|
    response.status_code = 200
    response << <<-XML
      <RemoveFromCollectionResult>
        <Message>1 item/s removed from UserPermission for User with ID U56</Message>
        <NumberOfItemsRemoved>1</NumberOfItemsRemoved>
      </RemoveFromCollectionResult>
    XML
  end

  result.get.should eq({
    "message"  => "1 item/s removed from UserPermission for User with ID U56",
    "modified" => 1,
  })
end
