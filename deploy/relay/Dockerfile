FROM node:22.19-alpine AS build

WORKDIR /app
RUN corepack enable

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/protocol/package.json packages/protocol/package.json
COPY packages/relay-server/package.json packages/relay-server/package.json
RUN pnpm install --frozen-lockfile

COPY packages/protocol packages/protocol
COPY packages/relay-server packages/relay-server
COPY scripts/install-public.sh /app/public-install.sh
COPY scripts/install-public-linux.sh /app/public-install-linux.sh
COPY scripts/install-public-windows.ps1 /app/public-install-windows.ps1
RUN pnpm --filter @dsh-anywhere/protocol build \
    && pnpm --filter @dsh-anywhere/relay-server build

FROM node:22.19-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY --from=build /app/package.json /app/pnpm-lock.yaml /app/pnpm-workspace.yaml ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/packages/protocol/package.json ./packages/protocol/package.json
COPY --from=build /app/packages/protocol/dist ./packages/protocol/dist
COPY --from=build /app/packages/protocol/node_modules ./packages/protocol/node_modules
COPY --from=build /app/packages/relay-server/package.json ./packages/relay-server/package.json
COPY --from=build /app/packages/relay-server/dist ./packages/relay-server/dist
COPY --from=build /app/packages/relay-server/node_modules ./packages/relay-server/node_modules
COPY --from=build /app/public-install.sh /app/public-install.sh
COPY --from=build /app/public-install-linux.sh /app/public-install-linux.sh
COPY --from=build /app/public-install-windows.ps1 /app/public-install-windows.ps1

RUN mkdir -p /data && chown -R node:node /data
# Bake the image build day where /health reads it from. Every rebuild
# re-stamps itself, so the deployment date is always current.
RUN date -u +%F > /app/BUILD_DATE
USER node
CMD ["node", "packages/relay-server/dist/index.js"]
