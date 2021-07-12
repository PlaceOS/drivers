# PlaceOS Drivers

[![CI](https://github.com/PlaceOS/drivers/actions/workflows/ci.yml/badge.svg)](https://github.com/PlaceOS/drivers/actions/workflows/ci.yml)

Manage and test [PlaceOS](https://place.technology) drivers.

## Development

### `harness`

`harness` is a helper for easing development of PlaceOS Drivers.

```
Usage: ./harness [-h|--help] [command]

Helper script for interfacing with the PlaceOS Driver spec runner

Command:
    report                  check all drivers' compilation status
    up                      starts the harness
    down                    stops the harness
    format                  formats driver code
    help                    display this message
```

To spin up the test harness, clone the repository and run...

```shell-session
$ ./harness up
```

Point a browser to [localhost:8085](http://localhost:8085), and you're good to go.

When the environment is not in use, remember to run...

```shell-session
$ ./harness down
```

Before committing, please run...

```shell-session
$ ./harness format
```

## Contributing

1. [Fork it](https://github.com/PlaceOS/drivers/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
