# The image the Linux UI tests run in: Swift, the GTK 4 and libsecret headers,
# a virtual display, a desktop keyring, and the accessibility bus the tests
# read the window through, with Python's bindings for it. CI installs the same
# list (packages.txt) into the same Swift image.
FROM swift:6.2.4-noble
COPY packages.txt /tmp/packages.txt
RUN apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive xargs -a /tmp/packages.txt \
        apt-get install -y -qq --no-install-recommends \
    && rm -rf /var/lib/apt/lists/* /tmp/packages.txt
