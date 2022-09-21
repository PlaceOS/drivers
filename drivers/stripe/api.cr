require "placeos-driver"
require "stripetease"

class Stripe::API < PlaceOS::Driver
  descriptive_name "Stripe API Gateway"
  generic_name :Payment
  uri_base "https://api.stripe.com"

  alias Client = Stripetease::Client

  default_settings({api_key: "ABCDEFGHIJKLMNOPQRSTUVWXYZ"})

  protected getter! client : Client

  def on_load
    on_update
  end

  def on_update
    host_name = config.uri.not_nil!.to_s
    api_key = setting(String, :api_key)

    @client = Stripetease::Client.new(base_url: host_name, api_key: api_key)
  end

  def add_payment_method(
    type : String,
    billing_details : Hash(String, String)? = nil,
    metadata : Hash(String, String)? = nil,
    acss_debit : Hash(String, String)? = nil,
    affirm : Hash(String, String)? = nil,
    afterpay_clearpay : Hash(String, String)? = nil,
    alipay : Hash(String, String)? = nil,
    au_becs_debit : Hash(String, String)? = nil,
    bacs_debit : Hash(String, String)? = nil,
    bancontact : Hash(String, String)? = nil,
    blik : Hash(String, String)? = nil,
    boleto : Hash(String, String)? = nil,
    card : Hash(String, String)? = nil,
    customer_balance : Hash(String, String)? = nil,
    eps : Hash(String, String)? = nil,
    fpx : Hash(String, String)? = nil,
    giropay : Hash(String, String)? = nil,
    ideal : Hash(String, String)? = nil,
    interac_present : Hash(String, String)? = nil,
    klarna : Hash(String, String)? = nil,
    konbini : Hash(String, String)? = nil,
    link : Hash(String, String)? = nil,
    oxxo : Hash(String, String)? = nil,
    p24 : Hash(String, String)? = nil,
    paynow : Hash(String, String)? = nil,
    promptpay : Hash(String, String)? = nil,
    radar_options : Hash(String, String)? = nil,
    sepa_debit : Hash(String, String)? = nil,
    sofort : Hash(String, String)? = nil,
    us_bank_account : Hash(String, String)? = nil,
    wechat_pay : Hash(String, String)? = nil
  )
    payment_method = @client.not_nil!.payment_methods.create(type, billing_details, metadata, acss_debit, affirm, afterpay_clearpay, alipay, au_becs_debit, bacs_debit, bancontact, blik, boleto, card, customer_balance, eps, fpx, giropay, ideal, interac_present, klarna, konbini, link, oxxo, p24, paynow, promptpay, radar_options, sepa_debit, sofort, us_bank_account, wechat_pay)
    self["payment_method"] = payment_method
  end

  def list_payment_methods(type : String, customer : String? = nil, ending_before : String? = nil, limit : Int32? = nil, starting_after : String? = nil)
    payment_methods = @client.not_nil!.payment_methods.list(type: type, customer: customer, ending_before: ending_before, limit: limit, starting_after: starting_after)
    self["payment_methods"] = payment_methods
  end

  def get_product_prices(active : Bool? = nil, currency : String? = nil, product : String? = nil, type : String? = nil, created : Hash(String, String)? = nil, ending_before : String? = nil, limit : Int32? = nil, lookup_keys : Array(String)? = nil, recurring : Hash(String, String)? = nil, starting_after : String? = nil)
    product_prices = @client.not_nil!.prices.list(active: active, currency: currency, product: product, type: type, created: created, ending_before: ending_before, limit: limit, lookup_keys: lookup_keys, recurring: recurring, starting_after: starting_after)
    self["product_prices"] = product_prices
  end

  def create_payment_intent(amount : Int32, currency : String, automatic_payment_methods : Hash(String, String)? = nil, confirm : Bool? = nil, customer : String? = nil, description : String? = nil, metadata : Hash(String, String)? = nil, off_session : Bool? = nil, payment_method : String? = nil, receipt_email : String? = nil, setup_future_usage : String? = nil, shipping : Hash(String, String)? = nil, statement_descriptor : String? = nil, statement_descriptor_suffix : String? = nil, application_fee_amount : Int32? = nil, capture_method : String? = nil, confrimation_method : String? = nil, error_on_requires_action : Bool? = nil, mandate : String? = nil, mandate_data : Hash(String, String)? = nil, on_behalf_of : String? = nil, payment_method_data : Hash(String, String)? = nil, payment_method_types : Array(String)? = nil, payment_method_options : Hash(String, String)? = nil, radar_options : Hash(String, String)? = nil, return_url : String? = nil, transfer_data : Hash(String, String)? = nil, transfer_group : String? = nil, use_stripe_sdk : Bool? = nil)
    payment_intent = @client.not_nil!.payment_intents.create(amount: amount, currency: currency, automatic_payment_methods: automatic_payment_methods, confirm: confirm, customer: customer, description: description, metadata: metadata, off_session: off_session, payment_method: payment_method, receipt_email: receipt_email, setup_future_usage: setup_future_usage, shipping: shipping, statement_descriptor: statement_descriptor, statement_descriptor_suffix: statement_descriptor_suffix, application_fee_amount: application_fee_amount, capture_method: capture_method, confrimation_method: confrimation_method, error_on_requires_action: error_on_requires_action, mandate_data: mandate_data, on_behalf_of: on_behalf_of, payment_method_data: payment_method_data, payment_method_types: payment_method_types, payment_method_options: payment_method_options, radar_options: radar_options, return_url: return_url, transfer_data: transfer_data, transfer_group: transfer_group, use_stripe_sdk: use_stripe_sdk)
    self["payment_intent"] = payment_intent
  end

  def confirm_payment_intent(id : String, payment_method : String? = nil, receipt_email : String? = nil, setup_future_usage : String? = nil, shipping : Hash(String, String)? = nil, capture_method : String? = nil, error_on_requires_action : Bool? = nil, mandate : String? = nil, mandate_data : Hash(String, String)? = nil, off_session : Bool? = nil, payment_method_data : Hash(String, String)? = nil, payment_method_options : Hash(String, String)? = nil, payment_method_types : Array(String)? = nil, radar_options : Hash(String, String)? = nil, return_url : String? = nil, use_stripe_sdk : Bool? = nil)
    payment_intent = @client.not_nil!.payment_intents.confirm(id: id, payment_method: payment_method, receipt_email: receipt_email, setup_future_usage: setup_future_usage, shipping: shipping, capture_method: capture_method, error_on_requires_action: error_on_requires_action, mandate: mandate, mandate_data: mandate_data, off_session: off_session, payment_method_data: payment_method_data, payment_method_options: payment_method_options, payment_method_types: payment_method_types, radar_options: radar_options, use_stripe_sdk: use_stripe_sdk)
    self["payment_intent"] = payment_intent
  end

  def cancel_payment_intent(id : String, cancellation_reason : String? = nil)
    @client.not_nil!.payment_intents.cancel(id: id, cancellation_reason: cancellation_reason)
    self["payment_intent"] = nil
  end

  def get_customer(id : String)
    self["customer"] = @client.not_nil!.customers.get(id)
  end

  def list_customers(email : String? = nil, created : Hash(String, String)? = nil, ending_before : String? = nil, limit : Int32? = nil, starting_after : String? = nil)
    self["customers"] = @client.not_nil!.customers.list(email: email, created: created, ending_before: ending_before, limit: limit, starting_after: starting_after)
  end

  def search_customers(query : String, limit : Int32? = nil, page : Int32? = nil)
    self["customers"] = @client.not_nil!.customers.search(query: query, limit: limit, page: page)
  end

  def create_customer(account_balance : Int32? = nil, coupon : String? = nil, default_source : String? = nil, description : String? = nil, email : String? = nil, invoice_prefix : String? = nil, metadata : Hash(String, String)? = nil, shipping : Hash(String, String)? = nil, source : String? = nil, tax_info : Hash(String, String)? = nil)
    customer = @client.not_nil!.customers.create(account_balance: account_balance, coupon: coupon, default_source: default_source, description: description, email: email, invoice_prefix: invoice_prefix, metadata: metadata, shipping: shipping, source: source, tax_info: tax_info)
    self["customer"] = customer
  end

  def update_customer(id : String, customer : String? = nil, account_balance : Int32? = nil, coupon : String? = nil, default_source : String? = nil, description : String? = nil, email : String? = nil, invoice_prefix : String? = nil, metadata : Hash(String, String)? = nil, shipping : Hash(String, String)? = nil, source : String? = nil, tax_info : Hash(String, String)? = nil)
    customer = @client.not_nil!.customers.update(id: id, customer: customer, account_balance: account_balance, coupon: coupon, default_source: default_source, description: description, email: email, invoice_prefix: invoice_prefix, metadata: metadata, shipping: shipping, source: source, tax_info: tax_info)
    self["customer"] = customer
  end
end
