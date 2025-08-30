# Multi-stage build for MCP Julia Server
FROM julia:1.11.2 AS builder

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy project files
COPY Project.toml Manifest.toml* ./
COPY src/ src/

# Precompile Julia packages
RUN julia --project=. -e "using Pkg; Pkg.instantiate(); Pkg.precompile()"

# Production stage
FROM julia:1.11.2-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libpq5 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r mcpserver && useradd -r -g mcpserver mcpserver

# Set working directory
WORKDIR /app

# Copy application from builder
COPY --from=builder /root/.julia /root/.julia
COPY --from=builder /app .
COPY *.jl ./
COPY .env.example .env

# Create data directory
RUN mkdir -p /app/data && chown -R mcpserver:mcpserver /app

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Switch to non-root user
USER mcpserver

# Expose port
EXPOSE 3000

# Set default environment variables
ENV POSTGRES_HOST=postgres \
    POSTGRES_PORT=5432 \
    POSTGRES_USER=postgres \
    POSTGRES_DB=mcpserver \
    MCP_FILE_SERVER_BASE=/app/data

# Default command (can be overridden)
CMD ["julia", "--project=.", "postgres_example.jl"]