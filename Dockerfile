FROM crystallang/crystal:0.32.1-alpine
COPY . /src
WORKDIR /src

# Build App
RUN rm -rf lib bin
RUN mkdir -p /src/bin/drivers
RUN shards build --error-trace --production

# Run the app binding on port 8080
EXPOSE 8080
ENTRYPOINT ["/src/bin/engine-drivers"]
CMD ["/src/bin/engine-drivers", "-b", "0.0.0.0", "-p", "8080"]
