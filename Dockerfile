FROM crystallang/crystal:0.32.1-alpine
COPY . /src
WORKDIR /src

# Install the latest version of LibSSH2
RUN apk update
RUN apk add libssh2 libssh2-dev

# Build App
RUN rm -rf lib bin
RUN mkdir -p /src/bin/drivers
RUN shards build --error-trace --production

# Run the app binding on port 8080
EXPOSE 8080
ENTRYPOINT ["/src/bin/engine-drivers"]
CMD ["/src/bin/engine-drivers", "-b", "0.0.0.0", "-p", "8080"]
