require "engine-driver"

# Dynamically require the desired driver
{{ ("require \"../" + env("COMPILE_DRIVER") + "\"").id }}
