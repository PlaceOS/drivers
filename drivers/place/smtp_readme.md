# SMTP Mailer Readme

Sends emails via SMTP. This is the terminal mailer in the chain (typically
`Mailer_2`, behind the Template Mailer) and is where email is actually delivered
to the SMTP server.

## Configuration

```yaml
  sender:            "support@place.tech"
  # host:            "smtp.host"
  # port:            587
  tls_mode:          "STARTTLS"   # or "SMTPS" / "NONE"
  ssl_verify_ignore: false
  username:          ""           # for SMTP servers requiring basic auth
  password:          ""

  # Optional: a reply-to address. When set, it overrides the reply-to on every
  # outbound email, regardless of any value supplied by upstream drivers or
  # templates (see Reply-To below).
  # reply_to: "noreply@place.tech"
```

## Reply-To

System-generated emails set a `Reply-To` header so replies reach a useful person
or mailbox rather than the no-reply sender address.

The `reply_to` setting on this driver is the **highest-priority** override in the
reply-to cascade: if configured, it is applied to all outbound mail and overrides
the per-template reply-to, the Template Mailer's tenant-wide setting, and the host
reply-to set by the sending drivers.

Leave it unset to allow the more specific reply-to values (per-template, Template
Mailer setting, or the host) to take effect. See the Template Mailer readme for
the full precedence cascade.
