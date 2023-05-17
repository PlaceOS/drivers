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
    build                   builds drivers and uploads them to S3
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

## Documentation

- [Existing Driver Docs](https://placeos.github.io/drivers/)
- [Writing a PlaceOS Driver](https://docs.placeos.com/tutorials/backend/write-a-driver)
- [Testing a PlaceOS Driver](https://docs.placeos.com/tutorials/backend/write-a-driver/testing-drivers)
- [Sending Emails](docs/guide-event-emails.md)
- [Environment Setup](docs/setup.md)
- [Runtime Debugging](docs/runtime-debugging.md)
- [Directory Structure](docs/directory_structure.md)
- [PlaceOS Spec Runner HTTP API](docs/http-api.md)

## Contributing

1. [Fork it](https://github.com/PlaceOS/drivers/fork)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request
