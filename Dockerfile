# Build and run the sync server.
#
# The build context is the repository root, not Server/, because the server
# package depends on the client package by path (`path: ".."`) so that the wire
# format has one definition rather than two that drift.
#
#   docker build -t wellspent-server .
#   docker run -p 8080:8080 -e DATABASE_URL=postgres://... wellspent-server

# ---- build ----------------------------------------------------------------
FROM swift:6.2-noble AS build

# Dependency resolution needs the manifests of both packages, and the path
# dependency means the parent's manifest has to be present too.
WORKDIR /build
COPY ./Package.swift ./Package.resolved ./
COPY ./Server/Package.swift ./Server/Package.resolved ./Server/
COPY ./Sources ./Sources

WORKDIR /build/Server
RUN swift package resolve

# Now the sources, so a change to code does not re-resolve dependencies.
#
# The server's test directory is copied even though nothing here runs tests.
# SwiftPM refuses to load a manifest whose declared target directories are
# missing, so omitting it fails the build with "Source files for target
# IntegrationTests should be located under Tests/IntegrationTests", which is not
# a Docker error and reads like one. It also has to be kept out of
# .dockerignore, or this line silently has nothing to copy.
WORKDIR /build
COPY ./Sources ./Sources
COPY ./Server/Sources ./Server/Sources
COPY ./Server/Tests ./Server/Tests

WORKDIR /build/Server
RUN swift build -c release --product WellSpentServer \
    -Xswiftc -g \
    --static-swift-stdlib

# Collect the binary and everything it needs into one directory.
RUN mkdir -p /staging \
 && cp "$(swift build -c release --show-bin-path)/WellSpentServer" /staging/ \
 && find -L "$(swift build -c release --show-bin-path)/" -regex '.*\.resources$' \
      -exec cp -Ra {} /staging/ \; || true

# ---- run ------------------------------------------------------------------
FROM ubuntu:noble

# ca-certificates for outbound TLS, tzdata so timestamps are not guesses.
RUN apt-get update -q \
 && DEBIAN_FRONTEND=noninteractive apt-get install -q -y \
      ca-certificates tzdata libcurl4 libxml2 \
 && rm -rf /var/lib/apt/lists/*

# Not root. A server that reads other people's financial records should not be
# able to rewrite its own binary.
RUN useradd --user-group --create-home --home-dir /app --shell /bin/false wellspent

WORKDIR /app
COPY --from=build --chown=wellspent:wellspent /staging /app

USER wellspent:wellspent
EXPOSE 8080

# Migrations run at boot. That is fine for one instance and wrong for several,
# because two starting at once will race. Run `migrate` as a release step and
# set SKIP_AUTO_MIGRATE before going multi-instance.
ENTRYPOINT ["./WellSpentServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
