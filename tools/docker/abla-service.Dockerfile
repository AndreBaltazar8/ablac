# Builds an Abla service (for example a game server) as a linux/amd64 image.
#
#   docker build --platform linux/amd64 \
#       -f tools/docker/abla-service.Dockerfile \
#       --build-context ablac=/path/to/ablac \
#       --build-context app=/path/to/app-sources \
#       --build-arg ENTRY=server/main.ab \
#       --build-arg ASSETS="data/maps" --build-arg APP_WORKDIR=. \
#       -t my-service .
#
# ASSETS lists app-context paths (files or directories) copied into the
# image under /app, and APP_WORKDIR (relative to /app) is the service's
# working directory, so relative runtime paths resolve as in development.
#
# Stage 1 bootstraps the pinned release compiler and rebuilds the compiler
# from the `ablac` context so the service compiles with the same sources it
# was developed against. Stage 2 compiles the service. The runtime stage
# carries only the binary plus the system libraries it links: glibc, and
# OpenSSL when the program imports TLS, JWT, or the async HTTPS client.

FROM ubuntu:24.04 AS toolchain
ARG LLVM_VERSION=21
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release wget software-properties-common \
        make git libssl-dev libffi-dev libedit-dev zlib1g-dev \
    && wget -q https://apt.llvm.org/llvm.sh \
    && bash llvm.sh ${LLVM_VERSION} \
    && apt-get install -y --no-install-recommends \
        lld-${LLVM_VERSION} llvm-${LLVM_VERSION}-dev libllvm${LLVM_VERSION} \
    && rm -rf /var/lib/apt/lists/* llvm.sh
ENV PATH=/usr/lib/llvm-${LLVM_VERSION}/bin:$PATH

FROM toolchain AS compiler
COPY --from=ablac . /opt/ablac
WORKDIR /opt/ablac
# The published bootstrap compiler was linked inside the Nix toolchain shell;
# point its ELF interpreter path at the system loader.
RUN rm -rf build && tools/bootstrap-compiler.sh build/ablac.bin \
    && interpreter=$(readelf -l build/ablac.bin | sed -n 's/.*interpreter: \(.*\)]/\1/p') \
    && if [ -n "$interpreter" ] && [ ! -e "$interpreter" ]; then \
           mkdir -p "$(dirname "$interpreter")" \
           && ln -s /lib64/ld-linux-x86-64.so.2 "$interpreter"; \
       fi \
    && ABLA_SYSROOT=/opt/ablac ABLA_MAX_MEMORY_MB=6000 ABLA_MAX_SECONDS=3000 \
        tools/run-limited.sh build/ablac.bin build src/orc_main.ab \
        -o build/ablac-current --no-cache \
    && mv build/ablac-current build/ablac.bin \
    && rm -f build/ablac-current.ll

FROM compiler AS build
ARG ENTRY=main.ab
ARG OUTPUT=service
ARG ASSETS=""
COPY --from=app . /src
WORKDIR /src
RUN ABLA_SYSROOT=/opt/ablac ABLA_MAX_MEMORY_MB=6000 ABLA_MAX_SECONDS=1800 \
        /opt/ablac/tools/run-limited.sh /opt/ablac/build/ablac.bin \
        build "${ENTRY}" -o "/out/${OUTPUT}" --no-cache \
    && test -x "/out/${OUTPUT}" \
    && ldd "/out/${OUTPUT}" \
    && mkdir -p /out/app \
    && for asset in ${ASSETS}; do \
           mkdir -p "/out/app/$(dirname "$asset")" && cp -R "/src/$asset" "/out/app/$asset"; \
       done

FROM ubuntu:24.04 AS runtime
ARG OUTPUT=service
ARG APP_WORKDIR=.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 abla
COPY --from=build /out/${OUTPUT} /usr/local/bin/service
COPY --from=build /out/app/ /app/
WORKDIR /app/${APP_WORKDIR}
USER abla
# Abla services drain on SIGTERM (WebSocketServer.enableGracefulShutdown).
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/service"]
