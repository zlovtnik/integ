# ==============================================================================
# Stage 1: Build
# ==============================================================================
FROM hexpm/elixir:1.15.7-erlang-26.2-debian-bookworm-20231009-slim AS builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y \
    build-essential \
    git \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set build ENV
ENV MIX_ENV=prod

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies first (caching layer)
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy config files
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy application code
COPY lib lib
COPY priv priv

# Compile and build release
RUN mix compile
COPY config/runtime.exs config/
RUN mix release

# ==============================================================================
# Stage 2: Runtime
# ==============================================================================
FROM debian:bookworm-slim AS app

# Install runtime dependencies and set the locale
RUN apt-get update -y && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
    ca-certificates \
    libaio1 \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Create app user
RUN useradd --create-home app
WORKDIR /home/app

# Create directories for Oracle wallet
RUN mkdir -p /home/app/wallet && chown app:app /home/app/wallet

# Copy release from builder
COPY --from=builder --chown=app:app /app/_build/prod/rel/gprint_ex ./

# Switch to non-root user
USER app

# Set runtime environment
ENV HOME=/home/app
ENV MIX_ENV=prod
ENV PHX_SERVER=true

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:${PORT:-4000}/api/health || exit 1

# Expose port
EXPOSE 4000

# Start the application
CMD ["bin/gprint_ex", "start"]
