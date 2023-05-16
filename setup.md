# Setup

Usage of [PlaceOS Driver Spec Runner](https://github.com/PlaceOS/driver-spec-runner) allows you to build and test
drivers without installing or running the complete PlaceOS service.

## Installation

Clone the drivers repository: `git clone https://github.com/placeos/drivers drivers`

## Reports

Test your driver with `./harness report <your_spec_file>`.
If the spec file argument is omitted, the harness will run specs for every driver in the current repository.

## Developing

After running `./harness up`, the harness will expose a development interface on [localhost:8085](http://localhost:8085).
