require "placeos-driver"
require "uri"
require "uuid"
require "digest/sha256"
require "./payments_models"

# Payment driver for the PlaceOS apps, with Stripe as the provider.
#
# Contract: `docs/payments.md` and `libs/payments/src/lib/payment.types.ts` of
# https://github.com/PlaceOS/user-interfaces
# Stripe API: https://docs.stripe.com/api
#
# - A payment ID is the Checkout Session ID (`cs_`) until the user pays on the
#   hosted page. After that it is the PaymentIntent ID (`pi_`), and
#   `get_payment` of the session returns the PaymentIntent. All methods
#   accept both IDs.
# - The line items, the user and the reference of a payment are stored in the
#   PaymentIntent metadata.
# - Lists use the Stripe Search API. New and changed payments and invoices can
#   take up to a minute to show in a list.
class Stripe::Payments < PlaceOS::Driver
  descriptive_name "Stripe Payments"
  generic_name :Payments
  uri_base "https://api.stripe.com"
  description <<-DESC
    Payments for bookings and catering in the PlaceOS apps. Users pay on the
    Stripe hosted page. Add the system of this module as the `payments`
    binding of the building or organisation zone. Requires a StaffAPI module
    in the same system. `api_key` is a Stripe secret or restricted key with
    write access to Customers, Checkout Sessions, PaymentIntents, Payment
    Methods, Refunds, Products, Prices, Invoices and Invoice Items.
    `tax_rate` is the percent of tax included in the prices, e.g. 10 for GST.
    Users in `privileged_groups`, and system admins, manage the payments,
    invoices and products of all users.
    DESC

  default_settings({
    api_key:           "sk_test_your_key",
    currency:          "AUD",
    tax_rate:          0.0,
    privileged_groups: ["payments-admin"],
    # verify the TLS certificate of Stripe. The transport skips it by default
    https_verify: "peer",
  })

  accessor staff_api : StaffAPI_1

  # Stripe API version that the models follow
  API_VERSION  = "2024-06-20"
  CAPABILITIES = ["saved_methods", "refunds", "invoices", "manual_capture"]

  MAX_ITEMS         =   50
  MAX_QUANTITY      = 1000
  MAX_DURATION      = 366 * 24 * 60
  MAX_PAGE_SIZE     =  100
  MAX_PRODUCT_PAGES =   10
  MAX_CATERERS      =   20
  MAX_CACHE_SIZE    = 1000
  MAX_REQUEST_ID    =  100
  # Stripe limits a metadata value to 500 characters and an object to 50 keys
  METADATA_VALUE_SIZE = 500
  MAX_ITEM_CHUNKS     =  30
  # Seconds that a link to confirm a saved method payment is valid for
  LINK_EXPIRY    = 3600_i64
  PRODUCTS_TTL   = 1.minute
  CATERING_TYPES = "CATERING:"

  @api_key : String = ""
  @currency : String = "AUD"
  @tax_rate : Float64 = 0.0
  @privileged_groups : Array(String) = [] of String

  # Stripe customer IDs by PlaceOS user ID
  @customers = {} of String => String
  # One capture or cancel at a time, so two requests for a payment cannot
  # both read it before one of them changes it
  @lock = Mutex.new
  # The zone and the parent zone of a zone ID
  @zone_scopes = {} of String => Array(String)
  @products : Array(PaymentProduct)? = nil
  @products_at : Time::Instant = Time.instant

  def on_update
    @api_key = setting(String, :api_key)
    @currency = (setting?(String, :currency).presence || "AUD").upcase
    @tax_rate = setting?(Float64, :tax_rate) || 0.0
    @privileged_groups = setting?(Array(String), :privileged_groups) || [] of String
    @customers.clear
    @products = nil
  end

  # ===================================
  # Methods for all users
  # ===================================

  # Settings of the driver for the current user
  def get_config : PaymentConfig
    PaymentConfig.new("stripe", @currency, privileged?(current_user), CAPABILITIES)
  end

  # Price of the line items
  def quote(items : Array(LineItemRequest)) : PaymentQuote
    price(items)
  end

  # Start a payment. With a saved method the driver authorizes it, else it
  # returns the URL of the Stripe hosted page. Stripe replays the first
  # response for a retry with the same `idempotency_key` for 24 hours, when
  # the request is the same. A retry after a price change fails instead.
  def create_checkout(request : CheckoutRequest) : CheckoutSession
    key = request.idempotency_key
    raise "invalid idempotency_key" unless 0 < key.size <= 100
    user = current_user
    quote = price(request.items)
    raise "The price changed. Check the new price and try again." unless quote.total == request.expected_total
    raise "Nothing to pay" unless quote.total > 0
    customer = user_customer(user)
    meta = payment_metadata(user, request.description, quote.items)
    description = request.description[0, 200]
    idempotency_key = "placeos-checkout-#{user.id}-#{key}"

    if method_id = request.payment_method_id.presence
      method = own_method(method_id, customer)
      params = URI::Params{
        "amount"         => quote.total.to_s,
        "currency"       => quote.currency.downcase,
        "customer"       => customer,
        "payment_method" => method.id,
        "confirm"        => "true",
        "off_session"    => "false",
        "capture_method" => "manual",
        "return_url"     => request.return_url,
        "expand[]"       => "latest_charge",
      }
      params["description"] = description if description.presence
      add_metadata(params, "metadata", meta)
      intent = PaymentIntent.from_json stripe("POST", "/v1/payment_intents", params, idempotency_key)
      payment = to_payment(intent)
      return CheckoutSession.new(intent.id, payment.status, intent.created + LINK_EXPIRY, redirect_url(intent))
    end

    params = URI::Params{
      "mode"                                => "payment",
      "customer"                            => customer,
      "success_url"                         => request.return_url,
      "cancel_url"                          => request.cancel_url,
      "payment_intent_data[capture_method]" => "manual",
    }
    params["payment_intent_data[description]"] = description if description.presence
    params["payment_intent_data[setup_future_usage]"] = "on_session" if request.save_method
    quote.items.each_with_index do |item, index|
      prefix = "line_items[#{index}]"
      params["#{prefix}[quantity]"] = item.quantity.to_s
      params["#{prefix}[price_data][currency]"] = quote.currency.downcase
      params["#{prefix}[price_data][unit_amount]"] = item.unit_amount.to_s
      params["#{prefix}[price_data][product_data][name]"] = item.name.presence || item.resource_type.to_s
      params["#{prefix}[price_data][product_data][description]"] = item.description if item.description.presence
    end
    add_metadata(params, "metadata", meta)
    add_metadata(params, "payment_intent_data[metadata]", meta)
    session = CheckoutSessionObject.from_json stripe("POST", "/v1/checkout/sessions", params, idempotency_key)
    CheckoutSession.new(session.id, PaymentStatus::Pending, session.expires_at, session.url)
  end

  def get_payment(id : String) : Payment
    user = current_user
    to_payment owned(load(id), user)
  end

  # Link to the hosted page of a `pending` or `requires_action` payment. An
  # open Checkout Session keeps its URL, so the link is the same one. An
  # expired session is `cancelled` and has no link. `return_url` is part of
  # the contract, but Stripe keeps the URL of the first request.
  def get_payment_link(id : String, return_url : String) : HostedSession
    user = current_user
    payment = owned(load(id), user)
    case payment
    in CheckoutSessionObject
      url = payment.url
      raise "Payment is #{status_name(to_payment(payment))}" unless payment.status == "open" && url
      HostedSession.new(payment.id, url, payment.expires_at)
    in PaymentIntent
      url = redirect_url(payment)
      raise "Payment is #{status_name(to_payment(payment))}" unless payment.status == "requires_action" && url
      HostedSession.new(payment.id, url, Time.utc.to_unix + LINK_EXPIRY)
    end
  end

  # Take an authorized payment and link it to the booking or the event. The
  # items of `exclude_resource_ids` are not taken. With nothing left to take,
  # the payment is released. A payment that is already taken is linked and
  # the excluded items are refunded.
  def capture_payment(id : String, reference : PaymentReference, exclude_resource_ids : Array(String) = [] of String) : Payment
    user = current_user
    @lock.synchronize { capture(id, reference, exclude_resource_ids, user) }
  end

  protected def capture(id : String, reference : PaymentReference, exclude_resource_ids : Array(String), user : PlaceUser) : Payment
    intent = owned(load(id), user).as?(PaymentIntent)
    raise "Payment is pending" unless intent
    payment = to_payment(intent)

    # A repeated capture for the same reference returns the payment once it
    # is taken or released. Before that, the same reference does the steps
    # that a failed attempt did not finish.
    return payment if payment.reference == reference && intent.status.in?("succeeded", "canceled")
    raise "Payment is linked to another #{payment.reference.try(&.type)}" if payment.reference && payment.reference != reference

    exclude = exclude_resource_ids.reject(&.empty?)
    keep = payment.items.reject { |item| exclude.includes?(item.resource_id) }
    amount = keep.sum(0_i64, &.amount)
    meta = item_metadata(keep, intent.metadata).merge(reference_metadata(reference))

    case intent.status
    when "requires_capture"
      if amount > 0
        params = URI::Params{"amount_to_capture" => amount.to_s, "expand[]" => "latest_charge"}
        add_metadata(params, "metadata", meta)
        begin
          to_payment PaymentIntent.from_json(stripe("POST", "/v1/payment_intents/#{intent.id}/capture", params, "placeos-capture-#{intent.id}-#{reference.type}-#{reference.id}"))
        rescue error
          # A capture that ran at the same time can have taken the payment
          current = to_payment(load_intent(intent.id))
          return current if current.reference == reference && current.status.succeeded?
          raise error
        end
      else
        update_metadata(intent.id, meta)
        to_payment PaymentIntent.from_json(stripe("POST", "/v1/payment_intents/#{intent.id}/cancel", URI::Params{"expand[]" => "latest_charge"}))
      end
    when "succeeded"
      # Refund before the reference is saved. The key stops a second refund
      refund = payment.amount - payment.amount_refunded - amount
      create_refund(intent.id, refund, "excluded resources", user, "placeos-exclude-#{intent.id}-#{reference.type}-#{reference.id}") if refund > 0
      update_metadata(intent.id, meta)
      to_payment load_intent(intent.id)
    else
      raise "Payment is #{status_name(payment)}"
    end
  end

  # Release a payment that is not taken, refund a payment that is taken.
  # Users who are not privileged cannot cancel a payment with a reference.
  def cancel_payment(id : String) : Payment
    user = current_user
    @lock.synchronize { cancel(id, user) }
  end

  protected def cancel(id : String, user : PlaceUser) : Payment
    object = owned(load(id), user)
    payment = to_payment(object)
    raise "This payment is for a saved booking. Ask staff for a refund." if payment.reference && !privileged?(user)

    case object
    in CheckoutSessionObject
      return payment unless object.status == "open"
      to_payment CheckoutSessionObject.from_json(stripe("POST", "/v1/checkout/sessions/#{object.id}/expire"))
    in PaymentIntent
      case object.status
      when "canceled"
        payment
      when "succeeded"
        refund = payment.amount - payment.amount_refunded
        create_refund(object.id, refund, "cancelled", user) if refund > 0
        to_payment load_intent(object.id)
      when "processing"
        raise "Payment is processing. Try again later."
      else
        to_payment PaymentIntent.from_json(stripe("POST", "/v1/payment_intents/#{object.id}/cancel", URI::Params{"expand[]" => "latest_charge"}))
      end
    end
  end

  # Payments, newest first. Open hosted payments are not listed until the
  # user pays, as Stripe makes the PaymentIntent then.
  def list_payments(query : PaymentQuery) : PaymentPage(Payment)
    user = current_user
    clauses = ["metadata['placeos']:'true'"]
    if !privileged?(user)
      clauses << "metadata['placeos_user_id']:#{search_value(user.id)}"
    elsif email = query.user_email.presence
      clauses << "metadata['placeos_user_email']:#{search_value(email.downcase)}"
    end
    if status = query.status
      clauses << "status:'#{search_status(status)}'"
    end
    if reference_id = query.reference_id.presence
      clauses << "metadata['reference_id']:#{search_value(reference_id)}"
    end
    query.period_start.try { |time| clauses << "created>=#{time}" }
    query.period_end.try { |time| clauses << "created<#{time}" }

    result = search(PaymentIntent, "/v1/payment_intents/search", clauses, query.limit, query.cursor, "data.latest_charge")
    items = result.data.map { |intent| to_payment(intent) }
    # A Stripe status can be more than one payment status, e.g. refunds
    items.select!(&.status.==(query.status)) if query.status
    PaymentPage(Payment).new(items.sort_by! { |item| -item.created_at }, result.next_page)
  end

  # Saved cards of the current user
  def list_payment_methods : Array(PaymentMethod)
    user = current_user
    customer_id = user_customer(user)
    customer = Customer.from_json stripe("GET", "/v1/customers/#{customer_id}")
    default = customer.invoice_settings.try(&.default_payment_method)
    methods = StripeList(StripePaymentMethod).from_json stripe("GET", "/v1/customers/#{customer_id}/payment_methods", URI::Params{"type" => "card", "limit" => MAX_PAGE_SIZE.to_s})
    methods.data.map do |method|
      card = method.card || Card.from_json("{}")
      PaymentMethod.new(method.id, method.type, card.brand, card.last4, card.exp_month, card.exp_year, method.id == default)
    end
  end

  # Hosted page to add a card
  def create_setup_session(return_url : String) : HostedSession
    user = current_user
    params = URI::Params{
      "mode"                    => "setup",
      "customer"                => user_customer(user),
      "payment_method_types[0]" => "card",
      "success_url"             => return_url,
      "cancel_url"              => return_url,
    }
    session = CheckoutSessionObject.from_json stripe("POST", "/v1/checkout/sessions", params)
    HostedSession.new(session.id, session.url || raise("Stripe returned no setup URL"), session.expires_at)
  end

  def remove_payment_method(id : String) : Nil
    user = current_user
    method = own_method(id, user_customer(user))
    stripe("POST", "/v1/payment_methods/#{method.id}/detach")
    nil
  end

  # Ask for an invoice for a taken payment. The invoice is a Stripe draft with
  # the `requested` status until staff send it. Stripe sends it to
  # `billing.email`. A second request returns the invoice of the first.
  def request_invoice(payment_id : String, billing : BillingDetails) : Invoice
    user = current_user
    intent = owned(load(payment_id), user).as?(PaymentIntent)
    raise "Payment is pending" unless intent
    payment = to_payment(intent)
    raise "Payment is #{status_name(payment)}" unless payment.status.succeeded? || payment.status.partially_refunded?
    raise "Billing name and email are required" unless billing.name.presence && billing.email.presence

    if invoice_id = payment.invoice_id
      existing = to_invoice load_invoice(invoice_id)
      return existing unless existing.status.void?
    end

    meta = {
      "placeos_requested"  => "true",
      "payment_id"         => intent.id,
      "placeos_user_id"    => payment.user_id,
      "placeos_user_email" => payment.user_email,
      "placeos_user_name"  => payment.user_name,
      "billing_name"       => billing.name,
      "billing_email"      => billing.email,
      "billing_company"    => billing.company || "",
      "billing_tax_id"     => billing.tax_id || "",
      "billing_address"    => billing.address || "",
    }
    fields = {"Company" => billing.company, "Tax ID" => billing.tax_id}
    customer = invoice_customer(billing.email, billing.name, payment.user_id)
    # fixed keys, so a retry after a failure continues the same draft
    keys = "placeos-request-#{intent.id}-#{payment.invoice_id || "first"}"
    invoice = draft_invoice(customer, payment.currency, payment.description, payment.items, meta, 1, fields, keys)
    update_metadata(intent.id, {"invoice_id" => invoice.id})
    # read it again, as Stripe replays the first response to a retry
    to_invoice load_invoice(invoice.id)
  end

  # Invoices, newest first
  def list_invoices(query : InvoiceQuery) : PaymentPage(Invoice)
    user = current_user
    clauses = ["metadata['placeos']:'true'"]
    # by user ID, so a user who gets a reused email cannot see the invoices
    # of the old user
    if !privileged?(user)
      clauses << "metadata['placeos_user_id']:#{search_value(user.id)}"
    elsif email = query.user_email.presence
      clauses << "metadata['placeos_user_email']:#{search_value(email.downcase)}"
    end
    # An invoice is requested or draft until it is sent (see `to_invoice`),
    # so the search is wider and the page is filtered on the mapped status
    case query.status
    in Nil
    in .requested?
      clauses << "metadata['placeos_requested']:'true'" << "-metadata['placeos_sent']:'true'"
    in .draft?
      clauses << "-metadata['placeos_requested']:'true'" << "-metadata['placeos_sent']:'true'"
    in .open?, .paid?
      clauses << "status:'#{query.status.to_s.downcase}'" << "metadata['placeos_sent']:'true'"
    in .void?
      clauses << "status:'void'"
    end
    if payment_id = query.payment_id.presence
      clauses << "metadata['payment_id']:#{search_value(payment_id)}"
    end

    result = search(StripeInvoice, "/v1/invoices/search", clauses, query.limit, query.cursor)
    items = result.data.map { |invoice| to_invoice(invoice) }
    items.select!(&.status.==(query.status)) if query.status
    PaymentPage(Invoice).new(items.sort_by! { |item| -item.created_at }, result.next_page)
  end

  # Products. Archived products only when `include_inactive` is true
  def list_products(query : ProductQuery) : Array(PaymentProduct)
    products.select do |product|
      (query.include_inactive || product.active) && (query.resource_type.nil? || product.resource_type == query.resource_type)
    end
  end

  # ===================================
  # Methods for privileged users
  # ===================================

  # Refund a part of a payment, or all of it when `amount` is `nil`. A retry
  # with the same `request_id` returns the payment and does not refund again.
  def refund_payment(id : String, amount : Int64?, reason : String, request_id : String? = nil) : Payment
    user = privileged_user
    @lock.synchronize { refund(id, amount, reason, request_id.presence, user) }
  end

  protected def refund(id : String, amount : Int64?, reason : String, request_id : String?, user : PlaceUser) : Payment
    intent = owned(load(id), user).as?(PaymentIntent)
    raise "Payment is pending" unless intent
    payment = to_payment(intent)
    if request_id
      raise "Invalid request ID" unless request_id.size <= MAX_REQUEST_ID
      return payment if refund_made?(intent.id, request_id)
    end
    raise "Payment is #{status_name(payment)}" unless intent.status == "succeeded"
    refundable = payment.amount - payment.amount_refunded
    refund = amount || refundable
    raise "Invalid refund amount" unless 0 < refund <= refundable
    create_refund(intent.id, refund, reason, user, request_id: request_id)
    to_payment load_intent(intent.id)
  end

  # Send a requested or draft invoice, also one that a failed send left open
  # or paid. An invoice that is already sent is returned as it is. Stripe
  # sends it to the email of the invoice customer, so `email` must be `nil`
  # or that address.
  def send_invoice(id : String, email : String?) : Invoice
    privileged_user
    send_stripe_invoice(load_invoice(id), email)
  end

  # Make an invoice for products and services. With `send`, send it now
  def create_invoice(request : InvoiceCreateRequest) : Invoice
    privileged_user
    email = request.user_email.strip.downcase
    raise "Invalid email" unless email.includes?('@') && email.size <= 254
    raise "Due days must be 1 to 365" unless 1 <= request.due_days <= 365
    quote = price(request.items)
    raise "Nothing to invoice" if quote.items.empty?

    name = (request.user_name.presence || email)[0, 100]
    customer = invoice_customer(email, name, "staff")
    meta = {"placeos_user_email" => email, "placeos_user_name" => name}
    # The PlaceOS user with the email can see the invoice. Without one, for
    # example for a guest, only staff see it.
    if owner = (PlaceUser.from_json(staff_api.user(email).get_json) rescue nil)
      meta["placeos_user_id"] = owner.id
    end
    invoice = draft_invoice(customer, quote.currency, request.memo || "", quote.items, meta, request.due_days)
    request.send ? send_stripe_invoice(invoice, nil) : to_invoice(invoice)
  end

  # Make a product when it has no `id`, else change it. A new amount makes a
  # new Stripe default price, as prices cannot change. The old price stays.
  def save_product(product : PaymentProductInput) : PaymentProduct
    privileged_user
    raise "Name is required" unless product.name.presence
    raise "Products must use #{@currency}" unless product.currency.upcase == @currency
    raise "Invalid amount" unless 0 <= product.unit_amount <= 99_999_999
    meta = {
      "placeos"       => "true",
      "resource_type" => product.resource_type.to_s.underscore,
      "resource_ids"  => product.resource_ids.join(','),
      "zone_ids"      => product.zone_ids.join(','),
      "unit"          => product.unit.to_s.underscore,
    }
    raise "Too many resources or zones" if meta.values.any?(&.size.>(METADATA_VALUE_SIZE))

    params = URI::Params{
      "name"     => product.name[0, 250],
      "active"   => product.active.to_s,
      "expand[]" => "default_price",
    }
    add_metadata(params, "metadata", meta)

    if id = product.id.presence
      existing = products.find(&.id.==(id)) || raise "Product not found"
      params["description"] = product.description
      if existing.unit_amount != product.unit_amount || existing.currency != @currency
        price = Price.from_json stripe("POST", "/v1/prices", URI::Params{
          "product"     => existing.id,
          "currency"    => @currency.downcase,
          "unit_amount" => product.unit_amount.to_s,
        })
        params["default_price"] = price.id
      end
      saved = Product.from_json stripe("POST", "/v1/products/#{existing.id}", params)
    else
      params["description"] = product.description if product.description.presence
      params["default_price_data[currency]"] = @currency.downcase
      params["default_price_data[unit_amount]"] = product.unit_amount.to_s
      saved = Product.from_json stripe("POST", "/v1/products", params)
    end

    @products = nil
    to_product(saved) || raise "Stripe returned the product with no price"
  end

  # ===================================
  # Users and access
  # ===================================

  protected def current_user : PlaceUser
    id = invoked_by_user_id
    raise "Payments need a signed in user" unless id.presence && id != "exec-internal"
    PlaceUser.from_json staff_api.user(id).get_json
  end

  protected def privileged?(user : PlaceUser) : Bool
    !!user.sys_admin || !((user.groups || [] of String) & @privileged_groups).empty?
  end

  protected def privileged_user : PlaceUser
    user = current_user
    raise "You cannot manage payments" unless privileged?(user)
    user
  end

  # The payment when it is a PlaceOS payment that the user can see
  protected def owned(payment : T, user : PlaceUser) : T forall T
    meta = payment.metadata
    visible = meta["placeos"]? == "true" && (meta["placeos_user_id"]? == user.id || privileged?(user))
    raise "Payment not found" unless visible
    payment
  end

  # Saved payment method of the customer
  protected def own_method(id : String, customer : String) : StripePaymentMethod
    method = StripePaymentMethod.from_json stripe("GET", "/v1/payment_methods/#{safe_id(id)}")
    raise "Payment method not found" unless method.customer == customer
    method
  end

  # Stripe customer of a user, for payments and saved cards. Only a customer
  # with the ID of the user in its metadata is used, so a user who gets a
  # reused email cannot use the cards of the old user. The email list is
  # current. The search finds the customer after an email change, but it can
  # be up to a minute late.
  protected def user_customer(user : PlaceUser) : String
    if id = @customers[user.id]?
      return id
    end

    email = user.email.downcase
    list = StripeList(Customer).from_json stripe("GET", "/v1/customers", URI::Params{"email" => email, "limit" => MAX_PAGE_SIZE.to_s})
    customer = list.data.find { |item| item.metadata["placeos_user_id"]? == user.id }
    customer ||= search(Customer, "/v1/customers/search", ["metadata['placeos_user_id']:#{search_value(user.id)}"], 1, nil).data.first?
    id = if customer
           # keep the email current, so the next email list finds it
           stripe("POST", "/v1/customers/#{safe_id(customer.id)}", URI::Params{"email" => email}) unless customer.email.try(&.downcase) == email
           customer.id
         else
           params = URI::Params{"email" => email, "name" => user.name[0, 100], "metadata[placeos]" => "true", "metadata[placeos_user_id]" => user.id}
           Customer.from_json(stripe("POST", "/v1/customers", params, "placeos-customer-#{user.id}")).id
         end
    @customers.clear if @customers.size >= MAX_CACHE_SIZE
    @customers[user.id] = id
  end

  # Stripe customer that gets the invoices of an owner for an email and a
  # name. It has only these details, so an invoice never shows the details
  # of another customer with the same email. `owner` is a user ID or `staff`.
  protected def invoice_customer(email : String, name : String, owner : String) : String
    email = email.strip.downcase
    name = name.strip[0, 100]
    list = StripeList(Customer).from_json stripe("GET", "/v1/customers", URI::Params{"email" => email, "limit" => MAX_PAGE_SIZE.to_s})
    found = list.data.find { |customer| customer.metadata["placeos_billing_owner"]? == owner && customer.name == name }
    return found.id if found
    params = URI::Params{"email" => email, "name" => name, "metadata[placeos]" => "true", "metadata[placeos_billing_owner]" => owner}
    key = Digest::SHA256.hexdigest("#{owner}\n#{email}\n#{name}")
    Customer.from_json(stripe("POST", "/v1/customers", params, "placeos-billing-#{key}")).id
  end

  # ===================================
  # Pricing
  # ===================================

  protected def price(requests : Array(LineItemRequest)) : PaymentQuote
    raise "Too many items, the limit is #{MAX_ITEMS}" if requests.size > MAX_ITEMS
    # catering prices come from StaffAPI, so only other items need products
    catalogue = requests.all?(&.resource_type.catering?) ? [] of PaymentProduct : products.select(&.active)
    menus = {} of String => Array(PlaceAsset)
    items = requests.compact_map { |request| price_item(request, catalogue, menus) }
    total = items.sum(0_i64, &.amount)
    tax = (total * @tax_rate / (100.0 + @tax_rate)).round.to_i64
    PaymentQuote.new(@currency, items, total - tax, tax, total)
  end

  # Line item with the price of its product or catering menu item. `nil`
  # when nothing matches, as the item is then free.
  protected def price_item(request : LineItemRequest, catalogue : Array(PaymentProduct), menus : Hash(String, Array(PlaceAsset))) : LineItem?
    quantity = request.quantity || 1
    raise "Quantity must be 1 to #{MAX_QUANTITY}" unless 1 <= quantity <= MAX_QUANTITY
    duration = request.duration
    raise "Invalid duration" if duration && !(0 <= duration <= MAX_DURATION)
    name = request.name.try &.[0, 80]
    # StaffAPI puts the zone ID in a request path
    if zone_id = request.zone_id.presence
      raise "Invalid zone ID" unless zone_id.matches?(/\A[\w\-]{1,100}\z/)
    end

    if request.resource_type.catering?
      zone_id = request.zone_id.presence
      resource_id = request.resource_id.presence
      return unless zone_id && resource_id
      asset = (menus[zone_id] ||= catering_menu(zone_id)).find(&.id.==(resource_id))
      return unless asset
      data = asset.other_data || CateringData.from_json("{}")
      selected = request.option_ids || [] of String
      options = (data.options || [] of CateringOption).select { |option| selected.includes?(option.id) }
      unit_amount = ((data.unit_price || 0.0) + options.sum(0.0) { |option| option.unit_price || 0.0 }).round.to_i64
      return LineItem.new("", ResourceType::Catering, asset.id, (asset.name.presence || name || asset.id)[0, 80], options.join(", ", &.name)[0, 80], PaymentUnit::Item, quantity, unit_amount)
    end

    product = find_product(request, catalogue)
    return unless product
    # the amount of a price in another currency is not a price in this one
    raise "The price of #{product.name} is in #{product.currency}, not #{@currency}" unless product.currency == @currency
    minutes = duration || 60
    units = case product.unit
            in .hour? then (minutes / 60).ceil.to_i
            in .day?  then (minutes / (24 * 60)).ceil.to_i
            in .booking?, .item?
              1
            end
    LineItem.new(product.id, product.resource_type, request.resource_id || "", name.presence || product.name, product.name[0, 80], product.unit, Math.max(units, 1) * quantity, product.unit_amount)
  end

  # Product of an item. The most specific match wins: resource IDs, then
  # zones, then the type only. A service needs its `product_id`.
  protected def find_product(request : LineItemRequest, catalogue : Array(PaymentProduct)) : PaymentProduct?
    if product_id = request.product_id.presence
      return catalogue.find(&.id.==(product_id))
    end
    return if request.resource_type.service?

    resource_id = request.resource_id || ""
    scope = zone_scope(request.zone_id)
    catalogue.select { |product|
      product.resource_type == request.resource_type &&
        (product.resource_ids.empty? || product.resource_ids.includes?(resource_id)) &&
        (product.zone_ids.empty? || product.zone_ids.any? { |zone| scope.includes?(zone) })
    }.max_by? { |product| (product.resource_ids.empty? ? 0 : 2) + (product.zone_ids.empty? ? 0 : 1) }
  end

  # The zone and its parent, e.g. a level and its building
  protected def zone_scope(zone_id : String?) : Array(String)
    return [] of String unless zone_id = zone_id.presence
    @zone_scopes[zone_id] ||= begin
      @zone_scopes.clear if @zone_scopes.size >= MAX_CACHE_SIZE
      zone = PlaceZone.from_json staff_api.zone(zone_id).get_json
      [zone_id, zone.parent_id].compact
    end
  end

  # Catering menu of a building: the assets of the `CATERING:<caterer>` asset types
  protected def catering_menu(zone_id : String) : Array(PlaceAsset)
    types = Array(PlaceAssetType).from_json(staff_api.asset_types.get_json).select(&.name.starts_with?(CATERING_TYPES))
    types.first(MAX_CATERERS).flat_map do |type|
      Array(PlaceAsset).from_json staff_api.assets(type_id: type.id, zone_id: zone_id, limit: 500).get_json
    end
  end

  # All PlaceOS products, also archived ones. Cached for a short time, as
  # every quote needs them.
  protected def products : Array(PaymentProduct)
    if (cached = @products) && Time.instant - @products_at < PRODUCTS_TTL
      return cached
    end

    list = [] of PaymentProduct
    starting_after = nil
    complete = false
    MAX_PRODUCT_PAGES.times do
      params = URI::Params{"limit" => MAX_PAGE_SIZE.to_s, "expand[]" => "data.default_price"}
      params["starting_after"] = starting_after if starting_after
      page = StripeList(Product).from_json stripe("GET", "/v1/products", params)
      page.data.each { |product| to_product(product).try { |item| list << item } }
      last = page.data.last?
      unless page.has_more && last
        complete = true
        break
      end
      starting_after = last.id
    end
    # A part of the list makes the items of the missing products free
    raise "The Stripe account has more than #{MAX_PRODUCT_PAGES * MAX_PAGE_SIZE} products" unless complete
    @products_at = Time.instant
    @products = list
  end

  # `nil` for products that PlaceOS did not make
  protected def to_product(product : Product) : PaymentProduct?
    meta = product.metadata
    price = product.price
    resource_type = ResourceType.parse?(meta["resource_type"]? || "")
    return unless meta["placeos"]? == "true" && price && resource_type
    PaymentProduct.new(
      product.id, product.name, product.description || "", product.active, resource_type,
      meta.fetch("resource_ids", "").split(',', remove_empty: true),
      meta.fetch("zone_ids", "").split(',', remove_empty: true),
      PaymentUnit.parse?(meta["unit"]? || "") || PaymentUnit::Item,
      price.unit_amount || 0_i64, price.currency.upcase, product.created, product.updated
    )
  end

  # ===================================
  # Payments
  # ===================================

  # The PaymentIntent of a payment ID, or its Checkout Session when the user
  # has not paid yet
  protected def load(id : String) : PaymentIntent | CheckoutSessionObject
    if id.starts_with?("cs_")
      session = CheckoutSessionObject.from_json stripe("GET", "/v1/checkout/sessions/#{safe_id(id)}", URI::Params{
        "expand[]" => ["payment_intent", "payment_intent.latest_charge"],
      })
      session.intent || session
    elsif id.starts_with?("pi_")
      load_intent(id)
    else
      raise "Payment not found"
    end
  end

  protected def load_intent(id : String) : PaymentIntent
    PaymentIntent.from_json stripe("GET", "/v1/payment_intents/#{safe_id(id)}", URI::Params{"expand[]" => "latest_charge"})
  end

  protected def to_payment(intent : PaymentIntent) : Payment
    meta = intent.metadata
    charge = intent.charge
    # On API 2024-06-20 the part of an authorization that a partial capture
    # releases counts as refunded, so it is not part of `amount_refunded` here
    refunded = 0_i64
    if charge && intent.status == "succeeded"
      refunded = Math.max(0_i64, charge.amount_refunded - (charge.amount - charge.amount_captured))
    end
    status = case intent.status
             when "requires_capture" then PaymentStatus::Authorized
             when "requires_action"  then PaymentStatus::RequiresAction
             when "canceled"         then PaymentStatus::Cancelled
             when "succeeded"
               if refunded <= 0
                 PaymentStatus::Succeeded
               elsif refunded >= intent.amount_received
                 PaymentStatus::Refunded
               else
                 PaymentStatus::PartiallyRefunded
               end
             when "requires_payment_method"
               intent.last_payment_error ? PaymentStatus::Failed : PaymentStatus::Pending
             else
               PaymentStatus::Pending
             end
    details = charge.try(&.payment_method_details)
    method = details.try { |info| MethodSummary.new(info.type, info.card.try(&.brand) || "", info.card.try(&.last4) || "") }
    Payment.new(
      intent.id, status, intent.status == "succeeded" ? intent.amount_received : intent.amount,
      refunded, intent.currency.upcase, intent.description || meta["description"]? || "",
      items_from(meta), meta["placeos_user_id"]? || "", meta["placeos_user_email"]? || "",
      meta["placeos_user_name"]? || "", reference_from(meta), method, charge.try(&.receipt_url),
      meta["invoice_id"]?.presence, intent.created, intent.created
    )
  end

  protected def to_payment(session : CheckoutSessionObject) : Payment
    meta = session.metadata
    status = session.status == "expired" ? PaymentStatus::Cancelled : PaymentStatus::Pending
    Payment.new(
      session.id, status, session.amount_total || 0_i64, 0_i64, (session.currency || @currency).upcase,
      meta["description"]? || "", items_from(meta), meta["placeos_user_id"]? || "",
      meta["placeos_user_email"]? || "", meta["placeos_user_name"]? || "", nil, nil, nil, nil,
      session.created, session.created
    )
  end

  protected def redirect_url(intent : PaymentIntent) : String?
    intent.next_action.try(&.redirect_to_url).try(&.url)
  end

  protected def status_name(payment : Payment) : String
    payment.status.to_s.underscore
  end

  # Stripe PaymentIntent status of a payment status, for a search
  protected def search_status(status : PaymentStatus) : String
    case status
    in .pending?, .failed?                           then "requires_payment_method"
    in .requires_action?                             then "requires_action"
    in .authorized?                                  then "requires_capture"
    in .succeeded?, .partially_refunded?, .refunded? then "succeeded"
    in .cancelled?                                   then "canceled"
    end
  end

  protected def create_refund(intent_id : String, amount : Int64, reason : String, user : PlaceUser, idempotency_key : String? = nil, request_id : String? = nil) : Nil
    params = URI::Params{
      "payment_intent"            => intent_id,
      "amount"                    => amount.to_s,
      "metadata[reason]"          => reason[0, METADATA_VALUE_SIZE],
      "metadata[placeos_user_id]" => user.id,
    }
    params["metadata[placeos_request_id]"] = request_id if request_id
    stripe("POST", "/v1/refunds", params, idempotency_key)
  end

  # True when a refund of the payment has the request ID and did not fail.
  # It uses the list API, as the Search API can be up to a minute late.
  # It reads the last 100 refunds of the payment.
  protected def refund_made?(intent_id : String, request_id : String) : Bool
    refunds = StripeList(Refund).from_json stripe("GET", "/v1/refunds", URI::Params{
      "payment_intent" => intent_id,
      "limit"          => MAX_PAGE_SIZE.to_s,
    })
    refunds.data.any? { |refund| refund.metadata["placeos_request_id"]? == request_id && !refund.status.in?("failed", "canceled") }
  end

  protected def update_metadata(intent_id : String, meta : Hash(String, String)) : Nil
    params = URI::Params.new
    add_metadata(params, "metadata", meta)
    stripe("POST", "/v1/payment_intents/#{intent_id}", params)
  end

  protected def payment_metadata(user : PlaceUser, description : String, items : Array(LineItem)) : Hash(String, String)
    {
      "placeos"            => "true",
      "placeos_user_id"    => user.id,
      "placeos_user_email" => user.email.downcase,
      "placeos_user_name"  => user.name[0, 100],
      "description"        => description[0, 200],
    }.merge(item_metadata(items))
  end

  protected def reference_metadata(reference : PaymentReference) : Hash(String, String)
    {
      "reference_type"    => reference.type[0, 20],
      "reference_id"      => reference.id[0, 200],
      "reference_zone_id" => reference.zone_id.try(&.[0, 200]) || "",
    }
  end

  protected def reference_from(meta : Hash(String, String)) : PaymentReference?
    type = meta["reference_type"]?.presence
    id = meta["reference_id"]?.presence
    PaymentReference.new(type, id, meta["reference_zone_id"]?.presence) if type && id
  end

  # A line item in metadata, by position: product_id, resource_type,
  # resource_id, name, description, unit, quantity, unit_amount
  alias PackedItem = Tuple(String, ResourceType, String, String, String, PaymentUnit, Int32, Int64)

  # Metadata keys `items_0`, `items_1`... that hold the items as JSON. Keys
  # of `previous` that are not used now are cleared.
  protected def item_metadata(items : Array(LineItem), previous : Hash(String, String)? = nil) : Hash(String, String)
    packed = items.map { |item| {item.product_id, item.resource_type, item.resource_id, item.name, item.description, item.unit, item.quantity, item.unit_amount} }
    chunks = packed.to_json.chars.each_slice(METADATA_VALUE_SIZE).map(&.join).to_a
    raise "Too many items to store" if chunks.size > MAX_ITEM_CHUNKS
    meta = {} of String => String
    previous.try &.each_key { |key| meta[key] = "" if key.starts_with?("items_") }
    chunks.each_with_index { |chunk, index| meta["items_#{index}"] = chunk }
    meta
  end

  protected def items_from(meta : Hash(String, String)) : Array(LineItem)
    json = String.build do |io|
      MAX_ITEM_CHUNKS.times do |index|
        chunk = meta["items_#{index}"]?
        break unless chunk
        io << chunk
      end
    end
    return [] of LineItem if json.empty?
    Array(PackedItem).from_json(json).map { |item| LineItem.new(*item) }
  rescue JSON::ParseException
    [] of LineItem
  end

  # ===================================
  # Invoices
  # ===================================

  protected def load_invoice(id : String) : StripeInvoice
    invoice = StripeInvoice.from_json stripe("GET", "/v1/invoices/#{safe_id(id)}")
    raise "Invoice not found" unless invoice.metadata["placeos"]? == "true"
    invoice
  end

  # Draft invoice with an invoice item for each line item. The `placeos` tag
  # is set after all items exist, so lists and sends skip a draft that is
  # not complete. With `keys`, each request has a fixed idempotency key, so
  # a retry continues the same draft.
  protected def draft_invoice(customer : String, currency : String, memo : String, items : Array(LineItem), meta : Hash(String, String), due_days : Int32, fields = {} of String => String?, keys : String? = nil) : StripeInvoice
    params = URI::Params{
      "customer"                       => customer,
      "currency"                       => currency.downcase,
      "collection_method"              => "send_invoice",
      "days_until_due"                 => due_days.to_s,
      "auto_advance"                   => "false",
      "pending_invoice_items_behavior" => "exclude",
    }
    params["description"] = memo[0, 500] if memo.presence
    fields.compact_map { |name, value| {name, value} if value.presence }.each_with_index do |(name, value), index|
      params["custom_fields[#{index}][name]"] = name
      params["custom_fields[#{index}][value]"] = value.to_s[0, 140]
    end
    add_metadata(params, "metadata", meta.transform_values(&.[0, METADATA_VALUE_SIZE]).merge(item_metadata(items)))
    invoice = StripeInvoice.from_json stripe("POST", "/v1/invoices", params, keys.try { |prefix| "#{prefix}-invoice" })

    items.each_with_index do |item, index|
      stripe("POST", "/v1/invoiceitems", URI::Params{
        "customer"    => customer,
        "invoice"     => invoice.id,
        "currency"    => currency.downcase,
        "amount"      => item.amount.to_s,
        "description" => "#{item.name} x #{item.quantity}"[0, 500],
      }, keys.try { |prefix| "#{prefix}-item-#{index}" })
    end
    StripeInvoice.from_json stripe("POST", "/v1/invoices/#{invoice.id}", URI::Params{"metadata[placeos]" => "true"}, keys.try { |prefix| "#{prefix}-tag" })
  end

  # Finalize a draft, mark an invoice of a taken payment as paid, then let
  # Stripe email it to the invoice customer
  protected def send_stripe_invoice(invoice : StripeInvoice, email : String?) : Invoice
    recipient = invoice.customer_email || ""
    raise "Stripe sends this invoice to #{recipient}" if (address = email.presence) && address.strip.downcase != recipient.downcase
    return to_invoice(invoice) if invoice.metadata["placeos_sent"]? == "true"

    if invoice.status == "draft"
      invoice = StripeInvoice.from_json stripe("POST", "/v1/invoices/#{invoice.id}/finalize", URI::Params{"auto_advance" => "false"})
    end
    raise "Invoice is #{invoice.status}" unless invoice.status.in?("open", "paid")
    # Also after a send that failed after the finalize, so the user never
    # gets a payable invoice for a payment they made
    if invoice.status == "open" && invoice.metadata["payment_id"]?.presence
      invoice = StripeInvoice.from_json stripe("POST", "/v1/invoices/#{invoice.id}/pay", URI::Params{"paid_out_of_band" => "true"})
    end
    # a fixed key, so a retry after a failed marker write does not email it
    # again, while Stripe keeps the key (24 hours)
    stripe("POST", "/v1/invoices/#{invoice.id}/send", idempotency_key: "placeos-send-#{invoice.id}")
    to_invoice StripeInvoice.from_json(stripe("POST", "/v1/invoices/#{invoice.id}", URI::Params{"metadata[placeos_sent]" => "true"}))
  end

  protected def to_invoice(invoice : StripeInvoice) : Invoice
    meta = invoice.metadata
    # A finalized invoice that a send did not finish stays requested or
    # draft, with no links, so staff can send it again
    unsent = invoice.status.in?("open", "paid") && meta["placeos_sent"]? != "true"
    status = if invoice.status == "draft" || unsent
               meta["placeos_requested"]? == "true" ? InvoiceStatus::Requested : InvoiceStatus::Draft
             elsif invoice.status == "open"
               InvoiceStatus::Open
             elsif invoice.status == "paid"
               InvoiceStatus::Paid
             else
               InvoiceStatus::Void
             end
    billing = if name = meta["billing_name"]?.presence
                BillingDetails.new(name, meta["billing_email"]? || "", meta["billing_company"]?.presence, meta["billing_tax_id"]?.presence, meta["billing_address"]?.presence)
              end
    Invoice.new(
      invoice.id, (invoice.number unless unsent) || "", status, meta["payment_id"]?.presence,
      meta["placeos_user_email"]? || invoice.customer_email || "",
      meta["placeos_user_name"]? || invoice.customer_name || "",
      invoice.total, invoice.currency.upcase, items_from(meta), billing,
      invoice.description || "", (invoice.hosted_invoice_url unless unsent), (invoice.invoice_pdf unless unsent),
      invoice.created, (invoice.status_transitions.try(&.finalized_at) unless unsent || invoice.status == "draft"), invoice.due_date
    )
  end

  # ===================================
  # Stripe requests
  # ===================================

  # One page of a Stripe search. Clauses are joined with AND
  protected def search(klass : T.class, path : String, clauses : Array(String), limit : Int32?, cursor : String?, expand : String? = nil) : StripeList(T) forall T
    params = URI::Params{
      "query" => clauses.join(" AND "),
      "limit" => (limit || 20).clamp(1, MAX_PAGE_SIZE).to_s,
    }
    if page = cursor.presence
      raise "Invalid cursor" if page.size > 1000
      params["page"] = page
    end
    params["expand[]"] = expand if expand
    StripeList(T).from_json stripe("GET", path, params)
  end

  # Quoted value for a search query
  protected def search_value(value : String) : String
    "'#{value[0, 200].gsub('\\', "\\\\").gsub('\'', "\\'")}'"
  end

  # A Stripe ID that is safe to put in a path
  protected def safe_id(id : String) : String
    raise "Invalid ID" unless id.matches?(/\A[a-zA-Z0-9_]{1,255}\z/)
    id
  end

  protected def add_metadata(params : URI::Params, prefix : String, meta : Hash(String, String)) : Nil
    meta.each { |key, value| params["#{prefix}[#{key}]"] = value }
  end

  # Send a request to Stripe. Raises the Stripe error message on failure.
  # Every POST has an idempotency key, as the transport sends a POST again
  # after an IO error.
  protected def stripe(method : String, path : String, params : URI::Params = URI::Params.new, idempotency_key : String? = nil) : String
    headers = HTTP::Headers{
      "Authorization"  => "Bearer #{@api_key}",
      "Stripe-Version" => API_VERSION,
    }

    response = if method == "GET"
                 get(path, params: params, headers: headers)
               else
                 headers["Content-Type"] = "application/x-www-form-urlencoded"
                 headers["Idempotency-Key"] = (idempotency_key || "placeos-#{UUID.random}")[0, 255]
                 post(path, body: params.to_s, headers: headers)
               end
    return response.body if response.success?

    # The message can hold values that the user sent, so only the user sees it
    error = (ErrorResponse.from_json(response.body).error rescue nil)
    logger.warn { "Stripe #{method} #{path} failed with #{response.status_code} #{error.try(&.type)} #{error.try(&.code)}" }
    raise error.try(&.message).presence || "Stripe request failed with #{response.status_code}"
  end
end
