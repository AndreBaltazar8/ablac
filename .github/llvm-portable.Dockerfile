FROM ubuntu:22.04@sha256:3b06811b2afd352be909dd088a004166d665dc76d38b13eada33522a9d915c6f

# These are the build dependencies of the upstream LLVM source tree.
RUN DEBIAN_FRONTEND=noninteractive apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates cmake g++-12 git ninja-build nodejs patch python3 xz-utils zlib1g-dev libzstd-dev
