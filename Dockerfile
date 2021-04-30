FROM crystallang/crystal:1.0.0-alpine
WORKDIR /src

# Install the latest version of LibSSH2 and the GDB debugger
RUN apk add --no-cache \
    ca-certificates \
    gdb \
    iputils \
    libssh2 libssh2-dev libssh2-static \
    tzdata \
    yaml-static

# Add trusted CAs for communicating with external services
RUN update-ca-certificates

RUN mkdir -p /src/bin/drivers

COPY shard.yml /src/shard.yml
COPY shard.override.yml /src/shard.override.yml
COPY shard.lock /src/shard.lock

RUN shards install --production --ignore-crystal-version

COPY src /src/src
COPY spec /src/spec

# Build App
RUN shards build --error-trace --release --production --ignore-crystal-version

# Run the app binding on port 8080
EXPOSE 8080
ENTRYPOINT ["/src/bin/test-harness"]
CMD ["/src/bin/test-harness", "-b", "0.0.0.0", "-p", "8080"]
