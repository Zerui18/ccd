FROM ccd-base:latest

USER root

# Node.js is already in the base image (node:22-bookworm-slim)
# Add common Node.js development tools
RUN npm install -g \
    typescript \
    tsx \
    && rm -rf /root/.npm/_cacache

# Install pnpm and yarn
RUN corepack enable && corepack prepare pnpm@latest --activate

USER node

# Pre-configure npm cache location
ENV npm_config_cache=/home/node/.npm-cache
