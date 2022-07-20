require "placeos-driver/spec"

DriverSpecs.mock_driver "Crestron::Fusion" do
  pp "test"

  before_all do
    settings({
      security_level: 0,
      user_id:        "spec-user-id",
      api_pass_code:  "spec-api-pass-code",
      service_url:    "http://spec.example.com/RoomViewSE/APIService/",
      content_type:   "xml",
    })
  end

  before_each do
    pp "========================================"
  end

  it "returns rooms" do
    resp = exec(:get_rooms, "Meeting Room A")

    expect_http_request do |request, response|
      pp request

      response.status_code = 200
      response << rooms_xml_response
    end

    # resp.get
  end

  it "returns a room" do
    resp = exec(:get_room, "room-id")

    expect_http_request do |request, response|
      pp request

      response.status_code = 200
      response << rooms_xml_response
    end

    # resp.get
  end
end


private def rooms_xml_response
  <<-RESPONSE
  <Rooms>
    #{room_xml_response}
  </Rooms>
  RESPONSE
end

private def room_xml_response
  <<-RESPONSE
  <API_Room>
    <Alias></Alias>
    <Assets>
      <API_Asset>
        <AssetID></AssetID>
        <AssetName>APITest AssetName1 Name</AssetName>
        <AssetTag></AssetTag>
        <AssetTypeID>CDPLAYER</AssetTypeID>
        <ConnType></ConnType>
        <DateOfPurchase></DateOfPurchase>
        <DriverID></DriverID>
        <IPAddress></IPAddress>
        <IPID></IPID>
        <LastModified></LastModified>
        <LastService></LastService>
        <LifeSpanYears></LifeSpanYears>
        <MACAddress></MACAddress>
        <MaintenanceContractID></MaintenanceContractID>
        <Make></Make>
        <Model></Model>
        <Notes></Notes>
        <Password></Password>
        <Port></Port>
        <RoomID></RoomID>
        <SSL></SSL>
        <SerialNumber></SerialNumber>
        <ServiceInterval></ServiceInterval>
        <ServiceIntervalIncrement></ServiceIntervalIncrement>
        <Status></Status>
        <WarrantyExpiration></WarrantyExpiration>
      </API_Asset>       
    </Assets>
    <Description></Description>
    <DistributionGroupID>DEFAULT</DistributionGroupID>
    <EControlLink></EControlLink>
    <GroupwarePassword></GroupwarePassword>
    <GroupwareProviderType>None</GroupwareProviderType>
    <GroupwareURL></GroupwareURL>
    <GroupwareUserDomain></GroupwareUserDomain>
    <GroupwareUsername></GroupwareUsername>
    <LastModified></LastModified>
    <Location></Location>
    <ParentNodeID>ROOMS</ParentNodeID>
    <Persons>
      <API_Person>
        <Name>admin</Name>
        <Role>Attendee</Role>
        <RoleID>ATTENDEE</RoleID>
        <UserID>0bf34a53-3dd3-438d-b88f-bec77eab3009</UserID>
      </API_Person>
      <API_Person>
        <Name>admin</Name>
        <Role>Technician</Role>
        <RoleID>TECHNICIAN</RoleID>
        <UserID>0bf34a53-3dd3-438d-b88f-bec77eab3009</UserID>
      </API_Person>
    </Persons>
    <Processors>
      <API_Processor>
        <Autodiscover></Autodiscover>
        <ConnectInfo>0.0.0.0</ConnectInfo>
        <ConnectSSL></ConnectSSL>
        <Connected></Connected>
        <IPID></IPID>
        <LastModified></LastModified>
        <Location></Location>
        <ParentID></ParentID>
        <Password></Password>
        <Port>41794</Port>
        <ProcessorID></ProcessorID>
        <ProcessorName>APITest Processor1 Name</ProcessorName>
        <SecurePort>41796</SecurePort>
        <Symbols>
          <API_Symbol>
            <ConnectInfo></ConnectInfo>
            <IPID></IPID>
            <LastModified></LastModified>
            <NodeID></NodeID>
            <NodeText></NodeText>
            <Password></Password>
            <ProcessorID></ProcessorID>
            <ProcessorName></ProcessorName>
            <RoomID></RoomID>
            <Signals>
              <API_Signal>
                <AttributeID>DISPLAY_POWER</AttributeID>
                <AttributeName>APITest Signal1 AttributeName</AttributeName>
                <AttributeType></AttributeType>
                <DefaultIOMask></DefaultIOMask>
                <JoinNumber></JoinNumber>
                <LastModified></LastModified>
                <LogicalOperator></LogicalOperator>
                <Reserved></Reserved>
                <SignalID></SignalID>
                <SignalMaxValue></SignalMaxValue>
                <SignalMinValue></SignalMinValue>
                <SignalName>APITest Signal1 SignalName</SignalName>
                <Slot></Slot>
                <SymbolID></SymbolID>
                <SymbolName>APITest Signal1 SymbolName</SymbolName>
                <XmlName>APITest Signal1 XMLName</XmlName>
              </API_Signal>
            </Signals>
            <SymbolID></SymbolID>
            <SymbolName>APITest Symbol1 Name</SymbolName>
            <UserName></UserName>
            <Version></Version>
          </API_Symbol>
        </Symbols>
        <Username></Username>
      </API_Processor>        
    </Processors>
    <RoomID></RoomID>
    <RoomName>APITest FULL Room Name</RoomName>
    <SMTPAddress></SMTPAddress>
    <TimeZoneID>Eastern Standard Time</TimeZoneID>
    <WebCamLink></WebCamLink>
  </API_Room>
  RESPONSE
end
