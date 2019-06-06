# Setup

This allows you to build and test drivers without installing or running the complete
ACA Engine service.

1. clone the drivers repository: `git clone https://github.com/aca-labs/crystal-engine-drivers engine-drivers`
2. clone private repositories here: `mkdir ./engine-drivers/repositories`


## OSX

Install [Homebrew](https://brew.sh/) to install dependencies

* Install [Crystal Lang](https://crystal-lang.org/reference/installation/): `brew install crystal`
* Install libssh2: `brew install libssh2`
* Install redis: `brew install redis`

Ensure the following lines are in your `.bashrc` file

```shell
export PATH="/usr/local/opt/llvm/bin:$PATH"
export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/local/opt/openssl/lib/pkgconfig
```


## Running Specs

1. Ensure redis is running: `redis-server`
2. Launch application: `crystal run ./src/app.cr`
3. Browse to: http://localhost:3000/

Now you can build drivers and run specs:

* Build a drvier or spec: `curl -X POST "http://localhost:3000/build?driver=drivers/helvar/net.cr"`
* Run a spec: `curl -X POST "http://localhost:3000/test?driver=drivers/lutron/lighting.cr&spec=drivers/lutron/lighting_spec.cr"`

To build or test against drivers in private repositories include the repository param: `repository=private_drivers`
