# HTTP API

Primarily for development.


## GET /build

Returns the list of available drivers

* `repository=folder_name` (optional) if you wish to specify a third party repository
* `compiled=true` (optional) if you only want the list of compiled drivers

```json

["drivers/place/spec_helper.cr", "..."]
```


### GET /build/repositories

Returns the list of 3rd party repositories

```json

["private_drivers", "..."]
```


### GET /build/repository_commits

Returns the list of available commits at the repository level

* `repository=folder_name` (optional) if you wish to specify a third party repository
* `count=50` (optional) if you want more or less commits

```json

{
  "commit": "01519d6",
  "date": "2019-06-02T23:59:22+10:00",
  "author": "Stephen von Takach",
  "subject": "implement websocket spec runner"
}
```


### GET /build/{{escaped driver path}}

Returns the list of compiled versions of the specified file are available

```json

["private_drivers_cr_01519d6", "..."]
```


### GET /build/{{escaped driver path}}/commits

Returns the list of available commits for the current driver

* `repository=folder_name` (optional) if you wish to specify a third party repository
* `count=50` (optional) if you want more or less commits

```json

{
  "commit": "01519d6",
  "date": "2019-06-02T23:59:22+10:00",
  "author": "Stephen von Takach",
  "subject": "implement websocket spec runner"
}
```


### POST /build

compiles a driver

* `driver=drivers/path.cr` (required) the path to the driver
* `commit=01519d6` (optional) defaults to head


### DELETE /build/{{escaped driver path}}

deletes compiled versions of a driver

* `repository=folder_name` (optional) if you wish to specify a third party repository
* `commit=01519d6` (optional) deletes all versions of a driver if not specified


## GET /test

Lists the available specs

```json

["drivers/place/spec_helper_spec.cr", "..."]
```


### GET /test/{{escaped spec path}}/commits

Returns the list of available commits for the specified spec

* `repository=folder_name` (optional) if you wish to specify a third party repository
* `count=50` (optional) if you want more or less commits

```json

{
  "commit": "01519d6",
  "date": "2019-06-02T23:59:22+10:00",
  "author": "Stephen von Takach",
  "subject": "implement websocket spec runner"
}
```


### POST /test

Compiles and runs a spec and returns the output

* `repository=folder_name` (optional) if you wish to specify a third party repository
* `driver=drivers/path/to/file.cr` (required) the driver you want to test
* `spec=drivers/path/to/file_spec.cr` (required) the spec you want to run on the driver
* `commit=01519d6` (optional) the commit you would like the driver to be running at
* `spec_commit=01519d6` (optional) the commit you would like the spec to be running at
* `force=true` (optional) forces a re-compilation of the driver and spec
* `debug=true` (optional) compiles the files with debugging symbols

```text
Launching spec runner
Launching driver: /Users/steve/Documents/projects/placeos/drivers/bin/drivers/drivers_place_private_helper_cr_4f6e0cd
... starting driver IO services
... starting module
... waiting for module
... module connected
... enabling debug output
... starting spec
... spec complete
... terminating driver gracefully
Driver terminated with: 0


Finished in 15.65 milliseconds
0 examples, 0 failures, 0 errors, 0 pending

spec runner exited with 0
```


### WebSocket /test/run_spec

Same requirements as `POST /test` above however it streams the response
