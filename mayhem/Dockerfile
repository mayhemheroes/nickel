# Build Stage
FROM ghcr.io/evanrichter/cargo-fuzz:latest AS builder

## Add source code to the build stage.
ADD . /src
WORKDIR /src

# The base image ships an old nightly; nickel requires edition 2024 (Rust >= 1.85).
# Reinstall the toolchain fresh (rather than `rustup update`) to avoid an
# overlayfs cross-device rename error when replacing pre-existing components.
RUN rustup toolchain uninstall nightly && \
    rustup toolchain install nightly --profile minimal --component rust-src

RUN echo building instrumented harnesses && \
    bash -c "pushd fuzz && cargo +nightly -Z sparse-registry fuzz build && popd" && \
    mv fuzz/target/x86_64-unknown-linux-gnu/release/parsing /parsing && \
    echo done

RUN echo building non-instrumented harnesses && \
    export RUSTFLAGS="--cfg fuzzing -Clink-dead-code -Cdebug-assertions -C codegen-units=1" && \
    bash -c "pushd fuzz && cargo +nightly -Z sparse-registry build --release && popd" && \
    mv fuzz/target/release/parsing /parsing_no_inst && \
    echo done

# Package Stage
FROM rustlang/rust:nightly

COPY --from=builder /parsing /parsing_no_inst /
