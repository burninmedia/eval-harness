FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY . .

EXPOSE 3000

ENV NODE_ENV=production
ENV PORT=3000
ENV SESSION_SECRET=${SESSION_SECRET:-change-me-in-production}

CMD ["node", "src/index.js"]
