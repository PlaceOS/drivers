ARG crystal_version=1.0.0
FROM crystallang/crystal:${crystal_version}-alpine

RUN mkdir -p /app
WORKDIR /app
