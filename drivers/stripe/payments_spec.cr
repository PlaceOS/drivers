require "placeos-driver/spec"
require "uri"
require "./payments_models"

DriverSpecs.mock_driver "Stripe::Payments" do
  system({
    StaffAPI: {StaffAPIMock},
  })

  settings({
    api_key:           "sk_test_123",
    currency:          "AUD",
    tax_rate:          10.0,
    privileged_groups: ["payments-admin"],
  })

  items = [
    {resource_type: "room", resource_id: "room-1", zone_id: "zone-level", name: "Room One", duration: 90, quantity: 1},
    {resource_type: "room", resource_id: "room-2", zone_id: "zone-level", name: "Room Two", duration: 90},
    {resource_type: "catering", resource_id: "coffee", zone_id: "zone-building", quantity: 2, option_ids: ["oat"]},
    # no desk product, so the desk is free
    {resource_type: "desk", resource_id: "desk-1", zone_id: "zone-level"},
  ]

  # ===================================
  # Config and pricing
  # ===================================

  config = Stripe::PaymentConfig.from_json exec(:get_config, user_id: "user-2").get.to_json
  config.privileged.should be_false
  config.currency.should eq "AUD"
  config.capabilities.should contain "manual_capture"

  Stripe::PaymentConfig.from_json(exec(:get_config, user_id: "user-1").get.to_json).privileged.should be_true

  expect_raises(PlaceOS::Driver::RemoteException, "Payments need a signed in user") do
    exec(:get_config).get
  end

  quote = exec(:quote, items, user_id: "user-2")
  expect_http_request do |request, response|
    request.path.should eq "/v1/products"
    request.headers["Authorization"].should eq "Bearer sk_test_123"
    request.headers["Stripe-Version"].should eq "2024-06-20"
    reply response, {object: "list", has_more: false, data: products_json}
  end
  quote = Stripe::PaymentQuote.from_json quote.get.to_json
  # room-1 uses its own product, room-2 the building product. 90 minutes is 2 hours
  quote.items.map(&.amount).should eq [8000, 5000, 1000]
  quote.items.map(&.product_id).should eq ["prod_room_1", "prod_room", ""]
  quote.items[2].description.should eq "Oat milk"
  quote.total.should eq 14000
  quote.tax.should eq 1273
  quote.subtotal.should eq 12727

  # ===================================
  # Checkout on the hosted page
  # ===================================

  checkout = {
    idempotency_key: "key-1",
    items:           items,
    expected_total:  14000,
    description:     "Team meeting",
    return_url:      "https://example.com/assets/payment-complete.html?state=success",
    cancel_url:      "https://example.com/assets/payment-complete.html?state=cancel",
  }

  expect_raises(PlaceOS::Driver::RemoteException, "The price changed") do
    exec(:create_checkout, checkout.merge(expected_total: 100), user_id: "user-2").get
  end

  session = exec(:create_checkout, checkout, user_id: "user-2")
  expect_http_request do |request, response|
    request.path.should eq "/v1/customers"
    request.query_params["email"].should eq "user2@example.com"
    # a customer with the email of another user is not used
    reply response, {object: "list", has_more: false, data: [{id: "cus_old", email: "user2@example.com", metadata: {placeos_user_id: "user-9"}}]}
  end
  expect_http_request do |request, response|
    request.path.should eq "/v1/customers/search"
    request.query_params["query"].should eq "metadata['placeos_user_id']:'user-2'"
    reply response, {object: "search_result", has_more: false, data: [] of String}
  end
  expect_http_request do |request, response|
    request.path.should eq "/v1/customers"
    request.headers["Idempotency-Key"].should eq "placeos-customer-user-2"
    form(request)["metadata[placeos_user_id]"].should eq "user-2"
    reply response, {id: "cus_2", email: "user2@example.com"}
  end
  meta = {} of String => String
  session_meta = {} of String => String
  expect_http_request do |request, response|
    request.path.should eq "/v1/checkout/sessions"
    request.headers["Idempotency-Key"].should eq "placeos-checkout-user-2-key-1"
    params = form(request)
    params["mode"].should eq "payment"
    params["customer"].should eq "cus_2"
    params["payment_intent_data[capture_method]"].should eq "manual"
    params["line_items[0][price_data][unit_amount]"].should eq "4000"
    params["line_items[0][quantity]"].should eq "2"
    params["line_items[2][price_data][product_data][name]"].should eq "Coffee"
    params.any? { |key, _value| key.starts_with?("line_items[3]") }.should be_false
    params.each { |key, value| meta[$1] = value if key =~ /\Apayment_intent_data\[metadata\]\[(.+)\]\z/ }
    params.each { |key, value| session_meta[$1] = value if key =~ /\Ametadata\[(.+)\]\z/ }
    meta["placeos_user_id"].should eq "user-2"
    reply response, {id: "cs_1", status: "open", url: "https://checkout.stripe.com/c/pay/cs_1", expires_at: 1_700_086_400, created: 1_700_000_000, metadata: meta}
  end
  session = Stripe::CheckoutSession.from_json session.get.to_json
  session.payment_id.should eq "cs_1"
  session.status.should eq Stripe::PaymentStatus::Pending
  session.url.should eq "https://checkout.stripe.com/c/pay/cs_1"

  it "reopens and cancels an open hosted payment" do
    open_session = {id: "cs_1", status: "open", url: "https://checkout.stripe.com/c/pay/cs_1", expires_at: 1_700_086_400, created: 1_700_000_000, metadata: session_meta}
    link = exec(:get_payment_link, "cs_1", "https://example.com/done", user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, open_session
    end
    Stripe::HostedSession.from_json(link.get.to_json).url.should eq "https://checkout.stripe.com/c/pay/cs_1"

    cancelled = exec(:cancel_payment, "cs_1", user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, open_session
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/checkout/sessions/cs_1/expire"
      reply response, open_session.merge(status: "expired")
    end
    Stripe::Payment.from_json(cancelled.get.to_json).status.should eq Stripe::PaymentStatus::Cancelled
  end

  # the user paid, so the payment is the PaymentIntent of the session
  payment = exec(:get_payment, "cs_1", user_id: "user-2")
  expect_http_request do |request, response|
    request.path.should eq "/v1/checkout/sessions/cs_1"
    request.query_params.fetch_all("expand[]").should eq ["payment_intent", "payment_intent.latest_charge"]
    reply response, {id: "cs_1", status: "complete", expires_at: 1_700_086_400, created: 1_700_000_000, metadata: meta, payment_intent: intent_json("requires_capture", meta)}
  end
  payment = Stripe::Payment.from_json payment.get.to_json
  payment.id.should eq "pi_1"
  payment.status.should eq Stripe::PaymentStatus::Authorized
  payment.amount.should eq 14000
  payment.items.map(&.resource_id).should eq ["room-1", "room-2", "coffee"]
  payment.payment_method.try(&.last4).should eq "4242"

  it "hides the payments of other users" do
    result = exec(:get_payment, "pi_1", user_id: "user-3")
    expect_http_request do |_request, response|
      reply response, intent_json("requires_capture", meta)
    end
    expect_raises(PlaceOS::Driver::RemoteException, "Payment not found") { result.get }
  end

  it "releases an authorization that is not linked to a booking" do
    result = exec(:cancel_payment, "pi_1", user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, intent_json("requires_capture", meta)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/payment_intents/pi_1/cancel"
      reply response, intent_json("canceled", meta)
    end
    Stripe::Payment.from_json(result.get.to_json).status.should eq Stripe::PaymentStatus::Cancelled
  end

  it "finishes a release that failed after the reference was saved" do
    linked = meta.merge({"reference_type" => "event", "reference_id" => "event-4"})
    result = exec(:capture_payment, "pi_4", {type: "event", id: "event-4"}, ["room-1", "room-2", "coffee"], user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, intent_json("requires_capture", linked, id: "pi_4")
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/payment_intents/pi_4"
      reply response, intent_json("requires_capture", linked, id: "pi_4")
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/payment_intents/pi_4/cancel"
      reply response, intent_json("canceled", linked, id: "pi_4")
    end
    Stripe::Payment.from_json(result.get.to_json).status.should eq Stripe::PaymentStatus::Cancelled
  end

  it "refunds the declined room of a payment that is already taken" do
    result = exec(:capture_payment, "pi_3", {type: "event", id: "event-3"}, ["room-2"], user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, intent_json("succeeded", meta, id: "pi_3", received: 14000)
    end
    # the refund runs before the reference is saved, with a key per capture
    expect_http_request do |request, response|
      request.path.should eq "/v1/refunds"
      request.headers["Idempotency-Key"].should eq "placeos-exclude-pi_3-event-event-3"
      form(request)["amount"].should eq "5000"
      reply response, {id: "re_3", status: "succeeded"}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/payment_intents/pi_3"
      form(request)["metadata[reference_id]"].should eq "event-3"
      reply response, intent_json("succeeded", meta, id: "pi_3", received: 14000, refunded: 5000)
    end
    expect_http_request do |_request, response|
      reply response, intent_json("succeeded", meta.merge({"reference_type" => "event", "reference_id" => "event-3"}), id: "pi_3", received: 14000, refunded: 5000)
    end
    payment = Stripe::Payment.from_json result.get.to_json
    payment.amount_refunded.should eq 5000
    payment.reference.try(&.id).should eq "event-3"
  end

  # ===================================
  # Capture without the declined room
  # ===================================

  captured = exec(:capture_payment, "pi_1", {type: "event", id: "event-1"}, ["room-2"], user_id: "user-2")
  expect_http_request do |request, response|
    request.path.should eq "/v1/payment_intents/pi_1"
    reply response, intent_json("requires_capture", meta)
  end
  expect_http_request do |request, response|
    request.path.should eq "/v1/payment_intents/pi_1/capture"
    request.headers["Idempotency-Key"].should eq "placeos-capture-pi_1-event-event-1"
    params = form(request)
    params["amount_to_capture"].should eq "9000"
    params["metadata[reference_type]"].should eq "event"
    params["metadata[reference_id]"].should eq "event-1"
    params.each { |key, value| meta[$1] = value if key =~ /\Ametadata\[(.+)\]\z/ }
    meta.reject! { |_key, value| value.empty? }
    reply response, intent_json("succeeded", meta, received: 9000)
  end
  captured = Stripe::Payment.from_json captured.get.to_json
  # Stripe counts the released 5000 as refunded. It is not a refund
  captured.status.should eq Stripe::PaymentStatus::Succeeded
  captured.amount_refunded.should eq 0
  captured.amount.should eq 9000
  captured.items.map(&.resource_id).should eq ["room-1", "coffee"]
  captured.reference.try(&.id).should eq "event-1"

  # a repeated capture returns the payment
  again = exec(:capture_payment, "pi_1", {type: "event", id: "event-1"}, ["room-2"], user_id: "user-2")
  expect_http_request do |_request, response|
    reply response, intent_json("succeeded", meta, received: 9000)
  end
  Stripe::Payment.from_json(again.get.to_json).amount.should eq 9000

  # ===================================
  # Cancel and refund
  # ===================================

  it "refuses to cancel a saved booking for users who are not privileged" do
    result = exec(:cancel_payment, "pi_1", user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, intent_json("succeeded", meta, received: 9000)
    end
    expect_raises(PlaceOS::Driver::RemoteException, "Ask staff for a refund") { result.get }
  end

  it "refuses refunds from users who are not privileged" do
    expect_raises(PlaceOS::Driver::RemoteException, "You cannot manage payments") do
      exec(:refund_payment, "pi_1", 1000, "goodwill", user_id: "user-2").get
    end
  end

  refunded = exec(:refund_payment, "pi_1", 1000, "goodwill", user_id: "user-1")
  expect_http_request do |_request, response|
    reply response, intent_json("succeeded", meta, received: 9000)
  end
  expect_http_request do |request, response|
    request.path.should eq "/v1/refunds"
    # a key, so the transport retry of a POST cannot refund twice
    request.headers["Idempotency-Key"].should start_with "placeos-"
    params = form(request)
    params["payment_intent"].should eq "pi_1"
    params["amount"].should eq "1000"
    params["metadata[reason]"].should eq "goodwill"
    reply response, {id: "re_1", status: "succeeded"}
  end
  expect_http_request do |_request, response|
    reply response, intent_json("succeeded", meta, received: 9000, refunded: 1000)
  end
  refunded = Stripe::Payment.from_json refunded.get.to_json
  refunded.status.should eq Stripe::PaymentStatus::PartiallyRefunded
  refunded.amount_refunded.should eq 1000

  it "refunds once for a request ID" do
    first = exec(:refund_payment, "pi_1", 1000, "goodwill", "refund-1", user_id: "user-1")
    expect_http_request do |_request, response|
      reply response, intent_json("succeeded", meta, received: 9000)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/refunds"
      request.method.should eq "GET"
      request.query_params["payment_intent"].should eq "pi_1"
      reply response, {data: [{id: "re_0", status: "failed", metadata: {placeos_request_id: "refund-1"}}], has_more: false}
    end
    expect_http_request do |request, response|
      request.method.should eq "POST"
      form(request)["metadata[placeos_request_id]"].should eq "refund-1"
      reply response, {id: "re_1", status: "succeeded", metadata: {placeos_request_id: "refund-1"}}
    end
    expect_http_request do |_request, response|
      reply response, intent_json("succeeded", meta, received: 9000, refunded: 1000)
    end
    Stripe::Payment.from_json(first.get.to_json).amount_refunded.should eq 1000

    # the response was lost, so staff try again: no second refund
    retry = exec(:refund_payment, "pi_1", 1000, "goodwill", "refund-1", user_id: "user-1")
    expect_http_request do |_request, response|
      reply response, intent_json("succeeded", meta, received: 9000, refunded: 1000)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/refunds"
      reply response, {data: [{id: "re_1", status: "succeeded", metadata: {placeos_request_id: "refund-1"}}], has_more: false}
    end
    Stripe::Payment.from_json(retry.get.to_json).amount_refunded.should eq 1000
  end

  # ===================================
  # Checkout with a saved card that needs 3-D Secure
  # ===================================

  saved = exec(:create_checkout, checkout.merge(idempotency_key: "key-2", payment_method_id: "pm_1"), user_id: "user-2")
  expect_http_request do |request, response|
    request.path.should eq "/v1/payment_methods/pm_1"
    reply response, {id: "pm_1", type: "card", customer: "cus_2", card: {brand: "visa", last4: "4242", exp_month: 8, exp_year: 2030}}
  end
  expect_http_request do |request, response|
    request.path.should eq "/v1/payment_intents"
    request.headers["Idempotency-Key"].should eq "placeos-checkout-user-2-key-2"
    params = form(request)
    params["confirm"].should eq "true"
    params["capture_method"].should eq "manual"
    params["payment_method"].should eq "pm_1"
    params["amount"].should eq "14000"
    reply response, intent_json("requires_action", meta, id: "pi_2", next_action: {type: "redirect_to_url", redirect_to_url: {url: "https://hooks.stripe.com/3d_secure"}})
  end
  saved = Stripe::CheckoutSession.from_json saved.get.to_json
  saved.payment_id.should eq "pi_2"
  saved.status.should eq Stripe::PaymentStatus::RequiresAction
  saved.url.should eq "https://hooks.stripe.com/3d_secure"

  it "refuses the saved method of another customer" do
    result = exec(:create_checkout, checkout.merge(idempotency_key: "key-3", payment_method_id: "pm_9"), user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, {id: "pm_9", type: "card", customer: "cus_other"}
    end
    expect_raises(PlaceOS::Driver::RemoteException, "Payment method not found") { result.get }
  end

  it "adds and removes saved cards of the user" do
    setup = exec(:create_setup_session, "https://example.com/done", user_id: "user-2")
    expect_http_request do |request, response|
      request.path.should eq "/v1/checkout/sessions"
      params = form(request)
      params["mode"].should eq "setup"
      params["customer"].should eq "cus_2"
      params["success_url"].should eq "https://example.com/done"
      params["cancel_url"].should eq "https://example.com/done"
      reply response, {id: "cs_setup", status: "open", url: "https://checkout.stripe.com/c/setup", expires_at: 1_700_086_400, created: 1_700_000_000}
    end
    Stripe::HostedSession.from_json(setup.get.to_json).url.should eq "https://checkout.stripe.com/c/setup"

    methods = exec(:list_payment_methods, user_id: "user-2")
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers/cus_2"
      reply response, {id: "cus_2", invoice_settings: {default_payment_method: "pm_1"}}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers/cus_2/payment_methods"
      reply response, {object: "list", has_more: false, data: [{id: "pm_1", type: "card", customer: "cus_2", card: {brand: "visa", last4: "4242", exp_month: 8, exp_year: 2030}}]}
    end
    cards = Array(Stripe::PaymentMethod).from_json methods.get.to_json
    cards.map(&.last4).should eq ["4242"]
    cards.first.is_default.should be_true

    removed = exec(:remove_payment_method, "pm_1", user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, {id: "pm_1", type: "card", customer: "cus_2"}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/payment_methods/pm_1/detach"
      reply response, {id: "pm_1", type: "card"}
    end
    removed.get.raw.should be_nil
  end

  it "keeps the saved cards of a user whose email changed" do
    methods = exec(:list_payment_methods, user_id: "user-3")
    expect_http_request do |request, response|
      request.query_params["email"].should eq "user3@example.com"
      reply response, {object: "list", has_more: false, data: [] of String}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers/search"
      reply response, {object: "search_result", has_more: false, data: [{id: "cus_3", email: "old3@example.com", metadata: {placeos_user_id: "user-3"}}]}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers/cus_3"
      form(request)["email"].should eq "user3@example.com"
      reply response, {id: "cus_3", email: "user3@example.com"}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers/cus_3"
      reply response, {id: "cus_3"}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers/cus_3/payment_methods"
      reply response, {object: "list", has_more: false, data: [{id: "pm_3", type: "card", customer: "cus_3", card: {brand: "visa", last4: "1111", exp_month: 8, exp_year: 2030}}]}
    end
    Array(Stripe::PaymentMethod).from_json(methods.get.to_json).map(&.id).should eq ["pm_3"]
  end

  # ===================================
  # Lists
  # ===================================

  it "lists only the payments of a user who is not privileged" do
    list = exec(:list_payments, {user_email: "someone@example.com", status: "authorized", limit: 500}, user_id: "user-2")
    expect_http_request do |request, response|
      request.path.should eq "/v1/payment_intents/search"
      request.query_params["query"].should eq "metadata['placeos']:'true' AND metadata['placeos_user_id']:'user-2' AND status:'requires_capture'"
      request.query_params["limit"].should eq "100"
      reply response, {object: "search_result", data: [intent_json("requires_capture", meta)], has_more: true, next_page: "page_2"}
    end
    page = Stripe::PaymentPage(Stripe::Payment).from_json list.get.to_json
    page.items.map(&.id).should eq ["pi_1"]
    page.next_cursor.should eq "page_2"
  end

  it "lists only the invoices of a user who is not privileged" do
    list = exec(:list_invoices, {user_email: "someone@example.com"}, user_id: "user-2")
    expect_http_request do |request, response|
      # by user ID, as an email can move to another user
      request.query_params["query"].should eq "metadata['placeos']:'true' AND metadata['placeos_user_id']:'user-2'"
      reply response, {object: "search_result", data: [] of String, has_more: false}
    end
    Stripe::PaymentPage(Stripe::Invoice).from_json(list.get.to_json).items.should be_empty
  end

  # ===================================
  # Products
  # ===================================

  it "makes a new price when the amount of a product changes" do
    product = {
      id: "prod_room", name: "Meeting room", description: "Hourly rate", active: true,
      resource_type: "room", resource_ids: [] of String, zone_ids: ["zone-building"],
      unit: "hour", unit_amount: 3000, currency: "AUD",
    }
    result = exec(:save_product, product, user_id: "user-1")
    expect_http_request do |request, response|
      request.path.should eq "/v1/prices"
      form(request)["unit_amount"].should eq "3000"
      reply response, {id: "price_room_new", unit_amount: 3000, currency: "aud"}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/products/prod_room"
      params = form(request)
      params["default_price"].should eq "price_room_new"
      params["metadata[zone_ids]"].should eq "zone-building"
      reply response, product_json("prod_room", "", "zone-building", 3000, "price_room_new")
    end
    saved_product = Stripe::PaymentProduct.from_json result.get.to_json
    saved_product.unit_amount.should eq 3000
    saved_product.unit.should eq Stripe::PaymentUnit::Hour
  end

  # ===================================
  # Invoices
  # ===================================

  it "requests an invoice and staff send it" do
    paid = intent_json("succeeded", meta, received: 9000)
    result = exec(:request_invoice, "pi_1", {name: "User Two", email: "accounts@example.com", company: "Acme"}, user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, paid
    end
    # Stripe sends the invoice to the billing email, so it has a customer for it
    expect_http_request do |request, response|
      request.query_params["email"].should eq "accounts@example.com"
      # the billing customer of another owner is not used
      reply response, {object: "list", has_more: false, data: [{id: "cus_other", email: "accounts@example.com", name: "User Two", metadata: {placeos_billing_owner: "user-9"}}]}
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers"
      params = form(request)
      params["email"].should eq "accounts@example.com"
      params["name"].should eq "User Two"
      params["metadata[placeos_billing_owner]"].should eq "user-2"
      reply response, {id: "cus_billing", email: "accounts@example.com"}
    end
    invoice_meta = {} of String => String
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices"
      params = form(request)
      params["customer"].should eq "cus_billing"
      request.headers["Idempotency-Key"].should eq "placeos-request-pi_1-first-invoice"
      # not tagged until all items exist
      params["metadata[placeos]"]?.should be_nil
      params["custom_fields[0][name]"].should eq "Company"
      params.each { |key, value| invoice_meta[$1] = value if key =~ /\Ametadata\[(.+)\]\z/ }
      invoice_meta["placeos_requested"].should eq "true"
      reply response, invoice_json("draft", invoice_meta)
    end
    ["8000", "1000"].each_with_index do |amount, index|
      expect_http_request do |request, response|
        request.path.should eq "/v1/invoiceitems"
        # fixed keys, so a retry does not add an item twice
        request.headers["Idempotency-Key"].should eq "placeos-request-pi_1-first-item-#{index}"
        params = form(request)
        params["invoice"].should eq "in_1"
        params["amount"].should eq amount
        reply response, {id: "ii_1"}
      end
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1"
      form(request)["metadata[placeos]"].should eq "true"
      invoice_meta["placeos"] = "true"
      reply response, invoice_json("draft", invoice_meta)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/payment_intents/pi_1"
      form(request)["metadata[invoice_id]"].should eq "in_1"
      reply response, paid
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1"
      reply response, invoice_json("draft", invoice_meta)
    end
    invoice = Stripe::Invoice.from_json result.get.to_json
    invoice.status.should eq Stripe::InvoiceStatus::Requested
    invoice.billing.try(&.company).should eq "Acme"
    invoice.items.size.should eq 2

    # staff send it to the billing email, as Concierge does after a request
    sent = exec(:send_invoice, "in_1", "accounts@example.com", user_id: "user-1")
    expect_http_request do |_request, response|
      reply response, invoice_json("draft", invoice_meta)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1/finalize"
      reply response, invoice_json("open", invoice_meta)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1/pay"
      form(request)["paid_out_of_band"].should eq "true"
      reply response, invoice_json("paid", invoice_meta)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1/send"
      reply response, invoice_json("paid", invoice_meta)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1"
      form(request)["metadata[placeos_sent]"].should eq "true"
      reply response, invoice_json("paid", invoice_meta.merge({"placeos_sent" => "true"}))
    end
    Stripe::Invoice.from_json(sent.get.to_json).status.should eq Stripe::InvoiceStatus::Paid
  end

  it "keeps an invoice that a send did not finish in the requested list" do
    linked = {"placeos" => "true", "placeos_requested" => "true", "payment_id" => "pi_1", "placeos_user_email" => "user2@example.com"}
    list = exec(:list_invoices, {status: "requested"}, user_id: "user-1")
    expect_http_request do |request, response|
      request.query_params["query"].should eq "metadata['placeos']:'true' AND metadata['placeos_requested']:'true' AND -metadata['placeos_sent']:'true'"
      # a stale search result can still hold a sent invoice
      data = [invoice_json("open", linked), invoice_json("paid", linked, id: "in_2"), invoice_json("paid", linked.merge({"placeos_sent" => "true"}), id: "in_3")]
      reply response, {object: "search_result", has_more: false, data: data}
    end
    page = Stripe::PaymentPage(Stripe::Invoice).from_json list.get.to_json
    # stopped before /pay, and after /pay but before /send
    page.items.map(&.id).should eq ["in_1", "in_2"]
    page.items.map(&.status).uniq.should eq [Stripe::InvoiceStatus::Requested]
    page.items.map(&.url).compact.should be_empty

    # staff send it: it is marked paid before Stripe emails it
    sent = exec(:send_invoice, "in_1", nil, user_id: "user-1")
    expect_http_request do |_request, response|
      reply response, invoice_json("open", linked)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1/pay"
      reply response, invoice_json("paid", linked)
    end
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices/in_1/send"
      request.headers["Idempotency-Key"].should eq "placeos-send-in_1"
      reply response, invoice_json("paid", linked)
    end
    expect_http_request do |_request, response|
      reply response, invoice_json("paid", linked.merge({"placeos_sent" => "true"}))
    end
    Stripe::Invoice.from_json(sent.get.to_json).status.should eq Stripe::InvoiceStatus::Paid
  end

  it "gives a staff invoice to the PlaceOS user with the email" do
    request = {user_email: "User3@example.com", items: [{resource_type: "catering", resource_id: "coffee", zone_id: "zone-building"}], due_days: 14, send: false}
    created = exec(:create_invoice, request, user_id: "user-1")
    expect_http_request do |request, response|
      request.path.should eq "/v1/customers"
      reply response, {object: "list", has_more: false, data: [] of String}
    end
    expect_http_request do |_request, response|
      reply response, {id: "cus_billing", email: "user3@example.com"}
    end
    invoice_meta = {} of String => String
    expect_http_request do |request, response|
      request.path.should eq "/v1/invoices"
      form(request).each { |key, value| invoice_meta[$1] = value if key =~ /\Ametadata\[(.+)\]\z/ }
      invoice_meta["placeos_user_id"].should eq "user-3"
      reply response, invoice_json("draft", invoice_meta, id: "in_9")
    end
    expect_http_request do |request, response|
      form(request)["amount"].should eq "450"
      reply response, {id: "ii_1"}
    end
    expect_http_request do |_request, response|
      reply response, invoice_json("draft", invoice_meta.merge({"placeos" => "true"}), id: "in_9")
    end
    Stripe::Invoice.from_json(created.get.to_json).status.should eq Stripe::InvoiceStatus::Draft
  end

  it "refuses a price in another currency" do
    settings({api_key: "sk_test_123", currency: "USD", tax_rate: 10.0, privileged_groups: ["payments-admin"]})
    quote = exec(:quote, items, user_id: "user-2")
    expect_http_request do |_request, response|
      reply response, {object: "list", has_more: false, data: products_json}
    end
    expect_raises(PlaceOS::Driver::RemoteException, "is in AUD, not USD") { quote.get }
  end
end

def reply(response, body)
  response.status_code = 200
  response.headers["Content-Type"] = "application/json"
  response << body.to_json
end

def form(request) : URI::Params
  URI::Params.parse(request.body.try(&.gets_to_end) || "")
end

def product_json(id, resource_ids, zone_ids, amount, price_id)
  {
    id: id, name: "Meeting room", description: "Hourly rate", active: true,
    metadata: {placeos: "true", resource_type: "room", resource_ids: resource_ids, zone_ids: zone_ids, unit: "hour"},
    default_price: {id: price_id, unit_amount: amount, currency: "aud"},
    created: 1_690_000_000, updated: 1_690_000_000,
  }
end

def products_json
  [
    product_json("prod_room", "", "zone-building", 2500, "price_room"),
    product_json("prod_room_1", "room-1", "", 4000, "price_room_1"),
    # not made by PlaceOS
    {id: "prod_other", name: "Other", active: true, created: 1, updated: 1, default_price: {id: "price_other", unit_amount: 1, currency: "aud"}},
  ]
end

def intent_json(status, meta, id = "pi_1", received = 0, refunded = 0, next_action = nil)
  {
    id: id, object: "payment_intent", status: status, amount: 14000, amount_received: received,
    currency: "aud", customer: "cus_2", description: "Team meeting", metadata: meta,
    next_action: next_action, created: 1_700_000_000,
    # before API 2025-03-31 Stripe counts the release of a partial capture as refunded
    latest_charge: {
      id: "ch_1", amount: 14000, amount_captured: received,
      amount_refunded: refunded + (received > 0 ? 14000 - received : 0), receipt_url: "https://pay.stripe.com/receipts/1",
      payment_method_details: {type: "card", card: {brand: "visa", last4: "4242"}},
    },
  }
end

def invoice_json(status, meta, id = "in_1")
  {
    id: id, status: status, number: status == "draft" ? nil : "INV-0001", customer: "cus_billing",
    customer_email: "accounts@example.com", total: 9000, currency: "aud", metadata: meta,
    hosted_invoice_url: "https://invoice.stripe.com/i/1", created: 1_700_000_100,
  }
end

# :nodoc:
class StaffAPIMock < DriverSpecs::MockDriver
  USERS = {
    "user-1" => {id: "user-1", email: "staff@example.com", name: "Staff", groups: ["payments-admin"], sys_admin: false},
    "user-2" => {id: "user-2", email: "User2@example.com", name: "User Two", groups: ["staff"], sys_admin: false},
    "user-3" => {id: "user-3", email: "user3@example.com", name: "User Three", groups: [] of String, sys_admin: false},
  }

  # by ID or email, like the PlaceOS users API
  def user(id : String)
    USERS[id]? || USERS.values.find { |user| user[:email].downcase == id.downcase } || raise "User not found"
  end

  def zone(zone_id : String)
    {id: zone_id, parent_id: zone_id == "zone-level" ? "zone-building" : nil}
  end

  def asset_types(category_id : String? = nil, zone_id : String? = nil, brand : String? = nil, model_number : String? = nil)
    [{id: "type-catering", name: "CATERING:Cafe"}, {id: "type-desk", name: "Desk"}]
  end

  def assets(type_id : String? = nil, zone_id : String? = nil, limit : Int32 = 1000)
    return [] of String unless type_id == "type-catering" && zone_id == "zone-building"
    [{id: "coffee", name: "Coffee", other_data: {unit_price: 450, options: [{id: "oat", name: "Oat milk", unit_price: 50}, {id: "shot", name: "Extra shot", unit_price: 80}]}}]
  end
end
