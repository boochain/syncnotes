# 构建：docker build -f deploy/Dockerfile -t syncnotes-server .
FROM rust:1-bookworm AS build
WORKDIR /src
COPY server/ .
RUN cargo build --release

FROM debian:bookworm-slim
RUN useradd -r -u 10001 syncnotes && mkdir -p /data && chown syncnotes /data
COPY --from=build /src/target/release/syncnotes-server /usr/local/bin/
USER syncnotes
ENV SYNCNOTES_BIND=0.0.0.0:7700 SYNCNOTES_DB=/data/syncnotes.db SYNCNOTES_FILES=/data/files SYNCNOTES_MDNS=false
VOLUME /data
EXPOSE 7700
CMD ["syncnotes-server"]
