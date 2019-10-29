FROM crystallang/crystal:0.31.1
ADD . /src
WORKDIR /src

# Build App
RUN shards build --production

# Run tests
RUN crystal spec

# Run the app binding on port 8080
EXPOSE 8080
ENTRYPOINT ["/src/bin/app"]
CMD ["/src/bin/app", "-b", "0.0.0.0", "-p", "8080"]
