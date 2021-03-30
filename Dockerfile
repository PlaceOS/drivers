FROM crystallang/crystal:1.0.0-alpine
COPY . /src
WORKDIR /src

# Install the latest version of LibSSH2 and the GDB debugger
RUN apk update
RUN apk add --no-cache libssh2 libssh2-dev libssh2-static iputils gdb
RUN apk add --update yaml-static

# Add trusted CAs for communicating with external services
RUN apk update && apk add --no-cache ca-certificates tzdata && update-ca-certificates

# Build App
RUN rm -rf lib bin
RUN mkdir -p /src/bin/drivers
RUN shards build --error-trace --production --ignore-crystal-version

# Run the app binding on port 8080
EXPOSE 8080
ENTRYPOINT ["/src/bin/test-harness"]
CMD ["/src/bin/test-harness", "-b", "0.0.0.0", "-p", "8080"]
