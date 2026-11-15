FROM crystallang/crystal:1.16.1-alpine

WORKDIR /app

# Add build dependencies
RUN apk add --update --no-cache --force-overwrite \
      llvm18-dev llvm18-static g++ libxml2-static zstd-static make

# Copy source
COPY . /app/

# Build liger static binary
RUN shards build liger \
      --no-debug --progress --stats --production --static --release \
      --ignore-crystal-version && \
      mkdir -p build && \
      gzip -c bin/liger > build/liger_x86_64-unknown-linux-musl.gz
