require "placeos-driver/spec"

DriverSpecs.mock_driver "UbiPark::API" do
  # Users

  list_users = exec(:list_users, 10, 0, String.new)

  expect_http_request do |request, response|
    case "#{request.path}"
    when "/data/export/v1.0/user/list"
      response.status_code = 200
      response << %([
        {
          "RecordCount": 453,
          "MoreResultsAvailable": true,
          "Users": [
            {
              "userId": 9717,
              "firstName": "John",
              "lastName": "Smith",
              "phone": "Smith",
              "email": "johnsmith@ubipark.com",
              "hasCreditCard": true,
              "marketing": true,
              "updated": "true"
            }
          ]
        }
      ])
    else
      response.status_code = 500
      response << "expected get space details request"
    end
  end

  users = list_users.get.not_nil!
  users.as_a.first.["RecordCount"].as_i.should eq 453

  # User permits

  list_userpermits = exec(:list_userpermits, 0, 0, String.new, 0, 0)

  expect_http_request do |request, response|
    case "#{request.path}"
    when "/data/export/v1.0/userpermit/list"
      response.status_code = 200
      response << %([
        {
          "RecordCount": 453,
          "MoreResultsAvailable": true,
          "UserPermits": [
            {
              "userPermitId": 10917,
              "userId": 9717,
              "email": "string",
              "emailConfirmed": true,
              "firstName": "string",
              "lastName": "string",
              "phoneNo": "string",
              "permitId": 0,
              "permitName": "string",
              "carParkId": 0,
              "carParkName": "string",
              "approvalStatus": 0,
              "approvedBy": 0,
              "approved": "2024-04-11T14:48:28.487Z",
              "message": "string",
              "notes": "string",
              "effectiveFrom": "2024-04-11T14:48:28.487Z",
              "effectiveTo": "2024-04-11T14:48:28.487Z",
              "emailed": true,
              "notified": true,
              "userConfirmationRequired": true,
              "acknowledged": true,
              "paidTo": "2024-04-11T14:48:28.487Z",
              "paidToUTC": "2024-04-11T14:48:28.487Z",
              "address": "string",
              "suburb": "string",
              "stateId": 0,
              "postcode": "string",
              "ContactAddress": "string",
              "licensePlate": "string",
              "vehicleStateId": 0,
              "vehicleMake": "string",
              "vehicleModel": "string",
              "vehicleColour": "string",
              "courtesyPeriod": true,
              "expiryEmailed": true,
              "expiryNotified": true,
              "active": true,
              "inserted": "2024-04-11T14:48:28.487Z",
              "insertedBy": 0,
              "updated": "true",
              "updatedBy": 0,
              "tenantId": 0,
              "permitNotes": "string",
              "editVehicle": true,
              "editVehicleHours": 0,
              "editVehicleText": "string",
              "editVehicleTooltip": "string",
              "vehicleCountryId": 0,
              "paymentPostcode": "string",
              "paymentOccupants": 0,
              "reminderEmailed": true,
              "reminderNotified": true,
              "vehicleStateCode": "string",
              "permitCreated": "2024-04-11T14:48:28.488Z",
              "permitModified": "2024-04-11T14:48:28.488Z",
              "timezoneKey": "string",
              "permitType": 0,
              "partPayment": true,
              "permitExternalRef": "string",
              "airlineId": 0,
              "permitReasonId": 0,
              "externalRef": "string",
              "externalUserId": "string",
              "permitState": 0,
              "stateCode": "string",
              "permitGroupId": 0,
              "permitGroupCode": "string",
              "qRCode": true,
              "reservedBays": true,
              "userCancel": true,
              "userCancelHours1": 0,
              "userCancelFee1": 0,
              "userCancelHours2": 0,
              "userCancelFee2": 0,
              "Overstay": true,
              "OverstayEmailed": true,
              "OverstayNotified": true,
              "OverstayPayment": true,
              "StaffId": "string",
              "userChange": true,
              "UserChangeHours": 0,
              "userChangeTooltip": "string",
              "userChangeText": "string",
              "staffIdDisplay": true,
              "staffIdRequired": true,
              "permitSchedule": true,
              "schedule": true,
              "Mom": true,
              "monFrom": "2024-04-11T14:48:28.488Z",
              "monTo": "2024-04-11T14:48:28.488Z",
              "tue": true,
              "tueFrom": "2024-04-11T14:48:28.488Z",
              "tueTo": "2024-04-11T14:48:28.488Z",
              "wed": true,
              "wedFrom": "2024-04-11T14:48:28.488Z",
              "wedTo": "2024-04-11T14:48:28.488Z",
              "thu": true,
              "thuFrom": "2024-04-11T14:48:28.488Z",
              "thuTo": "2024-04-11T14:48:28.488Z",
              "fri": true,
              "friFrom": "2024-04-11T14:48:28.488Z",
              "friTo": "2024-04-11T14:48:28.488Z",
              "sat": true,
              "satFrom": "2024-04-11T14:48:28.488Z",
              "satTo": "2024-04-11T14:48:28.488Z",
              "sun": true,
              "sunFrom": "2024-04-11T14:48:28.488Z",
              "sunTo": "2024-04-11T14:48:28.488Z",
              "versionNo": 0,
              "reason": "string",
              "attachment": "string",
              "fileName": "string",
              "contentType": "string",
              "promoCodeId": 0,
              "promoCodeOneTimeUseId": 0,
              "promoCode": "string",
              "captureNumberPlate": true,
              "numberPlateRequired": true,
              "confirmLicensePlate": true,
              "groupPermit": true,
              "organisationName": "string",
              "organisationPrincipal": "string",
              "organiserFirstName": "string",
              "organiserLastName": "string",
              "organiserMobileNo": "string",
              "organiserEmail": "string",
              "contactPhoneNo": "string",
              "contactFaxNo": "string",
              "agencyName": "string",
              "agencyPhone": "string",
              "agencyContactName": "string",
              "agencyEmailAddress": "string",
              "vehicleTypeId": 0,
              "noChildren": 0,
              "NoAdults": 0,
              "noUnder5": 0,
              "entryID": 0,
              "noVehicles": 0,
              "transportCompanyName": "string",
              "groupPermitTypeId": 0,
              "multiDay": true,
              "customText": "string",
              "bayLabel": "string",
              "courtesyPeriodTooltip": "string",
              "courtesyPeriodText": "string",
              "courtesyPeriodNotValidText": "string",
              "zoneCode": "string",
              "permitAreaCode": "string",
              "siteCode": "string",
              "uniqueId": "string",
              "userCancelDays": 0,
              "userCancelHours": 0,
              "vehicleCountryCode": "string",
              "permitCourtesyPeriod": true,
              "courtesyPeriodTime": "2024-04-11T14:48:28.488Z",
              "startGraceDays": 0,
              "startGraceMins": 0,
              "endGraceDays": 0,
              "endGraceMins": 0,
              "userRefund": true,
              "userRefundFee": 0,
              "uploadDocument": true,
              "uploadDocumentLabel": "string",
              "documentUploadRequired": true,
              "documentDeleteAfterApproval": true,
              "overnight": true,
              "noSeats": 0,
              "leaderFirstName": "string",
              "leaderLastName": "string",
              "leaderMobileNo": "string",
              "leaderEmail": "string",
              "appID": 0,
              "customAdminValue": "string"
            }
          ]
        }
      ])
    else
      response.status_code = 500
      response << "expected get space details request"
    end
  end

  user_permits = list_userpermits.get.not_nil!
  user_permits.as_a.first.["RecordCount"].as_i.should eq 453

  # Products

  list_products = exec(:list_products, 1, nil)

  expect_http_request do |request, response|
    case "#{request.path}"
    when "/api/payment/productList"
      response.status_code = 200
      response << %([
        {
          "productID": "VALET",
          "description": "Premium Valet",
          "tenantID": 321,
          "carParkName": "Long Term Car Park",
          "carParkID": 321,
          "groupId": 321,
          "groupCode": "VALET",
          "groupDescription": "Valet Parking",
          "default": false,
          "permitType": 2,
          "yearType": 0,
          "yearDate": "2024-04-11T14:54:02.728Z",
          "monthType": 0,
          "monthDay": 0,
          "monthWeek": 0,
          "monthWeekDay": 0,
          "weekType": 0,
          "weekDay": 0,
          "multiDay": false,
          "recurring": false,
          "autoRenew": false,
          "autoApprove": false,
          "reminder": true,
          "reminderDays": true,
          "daysInAdvance": true,
          "effectiveFrom": "2020-02-01 00:00",
          "effectiveTo": "2025-02-01 00:00",
          "minPurchaseDate": "2025-02-01 00:00",
          "maxPurchaseDate": "2025-02-01 00:00",
          "previousDays": 0,
          "notes": "Billed every month in advance. Must park in speacial section.",
          "maxAvailable": 40,
          "addressRequired": false,
          "contactAddressRequired": false,
          "confirmLicensePlate": false,
          "vehicleDetailsRequired": false,
          "postPaymentRequired": false,
          "postcodeRequired": false,
          "occupantsRequired": false,
          "promoCode": true,
          "airlineDisplay": true,
          "airlineRequired": true,
          "permitReasonDisplay": true,
          "permitReasonRequired": true,
          "maxPurchaseDays": 12,
          "qrCode": true,
          "reservedBays": true,
          "overstayCharge": false,
          "staffIDRequired": false,
          "schedule": false,
          "userAccountRequired": false,
          "captureNumberPlate": false,
          "numberPlateRequired": false,
          "groupPermit": false,
          "paymentMessage": "false",
          "displayIfZeroAmount": false,
          "displayTermsAndConditions": false,
          "displayMarketing": false,
          "customText": "false",
          "customTextDisplay": false,
          "customTextRequired": false,
          "customWarningDisplay": false,
          "customWarning": "Details are required.",
          "eventType": "false",
          "eventDates": "false",
          "eventStartDate": "false",
          "eventEndDate": "false",
          "timezone": "AUS Eastern Standard Time",
          "closedDays": false
        }
      ])
    when "/api/payment/productList?#{request.query}"
      response.status_code = 200
      response << %([
        {
          "productID": "VALET",
          "description": "Premium Valet",
          "tenantID": 321,
          "carParkName": "Long Term Car Park",
          "carParkID": 321,
          "groupId": 321,
          "groupCode": "VALET",
          "groupDescription": "Valet Parking",
          "default": false,
          "permitType": 2,
          "yearType": 0,
          "yearDate": "2024-04-11T14:54:02.728Z",
          "monthType": 0,
          "monthDay": 0,
          "monthWeek": 0,
          "monthWeekDay": 0,
          "weekType": 0,
          "weekDay": 0,
          "multiDay": false,
          "recurring": false,
          "autoRenew": false,
          "autoApprove": false,
          "reminder": true,
          "reminderDays": true,
          "daysInAdvance": true,
          "effectiveFrom": "2020-02-01 00:00",
          "effectiveTo": "2025-02-01 00:00",
          "minPurchaseDate": "2025-02-01 00:00",
          "maxPurchaseDate": "2025-02-01 00:00",
          "previousDays": 0,
          "notes": "Billed every month in advance. Must park in speacial section.",
          "maxAvailable": 40,
          "addressRequired": false,
          "contactAddressRequired": false,
          "confirmLicensePlate": false,
          "vehicleDetailsRequired": false,
          "postPaymentRequired": false,
          "postcodeRequired": false,
          "occupantsRequired": false,
          "promoCode": true,
          "airlineDisplay": true,
          "airlineRequired": true,
          "permitReasonDisplay": true,
          "permitReasonRequired": true,
          "maxPurchaseDays": 12,
          "qrCode": true,
          "reservedBays": true,
          "overstayCharge": false,
          "staffIDRequired": false,
          "schedule": false,
          "userAccountRequired": false,
          "captureNumberPlate": false,
          "numberPlateRequired": false,
          "groupPermit": false,
          "paymentMessage": "false",
          "displayIfZeroAmount": false,
          "displayTermsAndConditions": false,
          "displayMarketing": false,
          "customText": "false",
          "customTextDisplay": false,
          "customTextRequired": false,
          "customWarningDisplay": false,
          "customWarning": "Details are required.",
          "eventType": "false",
          "eventDates": "false",
          "eventStartDate": "false",
          "eventEndDate": "false",
          "timezone": "AUS Eastern Standard Time",
          "closedDays": false
        }
      ])
    else
      response.status_code = 500
      response << "expected get space details request"
    end
  end

  products = list_products.get.not_nil!
  products.as_a.first.["productID"].as_s.should eq "VALET"

  # Reasons

  list_reasons = exec(:list_reasons, 1)

  expect_http_request do |request, response|
    case "#{request.path}"
    when "/api/payment/reasonList"
      response.status_code = 200
      response << %([
        {
          "tenantID": 12,
          "reasonID": "HOL",
          "description": "Holiday"
        }
      ])
    when "/api/payment/reasonList?#{request.query}"
      response.status_code = 200
      response << %([
        {
          "tenantID": 12,
          "reasonID": "HOL",
          "description": "Holiday"
        }
      ])
    else
      response.status_code = 500
      response << "expected get space details request"
    end
  end

  reasons = list_reasons.get.not_nil!
  reasons.as_a.first.["reasonID"].as_s.should eq "HOL"

  # Payments

  # payment_id : String, promise_pay_card_name : String, user_id : String, tenant_id : Int32, product_id : String, from_date : String, to_date : String, amount : Float64
  make_payment = exec(:make_payment, "1", "2", "3", 4, "5", "6", "7", 20.841)

  expect_http_request do |request, response|
    case "#{request.path}"
    when "/api/payment/makepayment"
      response.status_code = 200
      response << %({
        "success": true,
        "errors": [
          "string"
        ],
        "gatewayTimeout": false,
        "paymentHeld": false,
        "paymentID": "12345",
        "receiptNo": "987651",
        "amount": 20.84
      })
    else
      response.status_code = 500
      response << "expected get space details request"
    end
  end

  payment = make_payment.get.not_nil!
  payment["success"].as_bool.should eq true
end
