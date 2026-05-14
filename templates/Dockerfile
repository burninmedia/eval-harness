# syntax=docker/dockerfile:1
# Reference image — copy into your app repo and adjust COPY paths / env / health URL.
FROM node:20-bookworm-slim AS deps
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
  && rm -rf /var/lib/apt/lists/*
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:20-bookworm-slim AS runner
WORKDIR /app
RUN apt-get update \
  && apt-get install -y --no-install-recommends dumb-init ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --gid 1001 nodejs \
  && useradd --uid 1001 --gid nodejs --shell /usr/sbin/nologin nodejs

COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json ./
COPY src ./src
COPY public ./public

RUN mkdir -p /data && chown -R nodejs:nodejs /app /data

USER nodejs

ENV NODE_ENV=production
ENV PORT=3000
ENV DB_PATH=/data/app.sqlite

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "require('http').get('http://127.0.0.1:3000/health',(r)=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
