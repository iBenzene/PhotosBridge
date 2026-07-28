ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

WORKDIR /app
COPY package.json ./
COPY apps/server/package.json apps/server/package.json
RUN npm install

COPY apps/server apps/server
RUN npm run build:server

ENV PORT=8787
ENV DATABASE_PATH=/data/photos-bridge.sqlite
EXPOSE 8787
VOLUME ["/data"]
CMD ["npm", "--workspace", "@photos-bridge/server", "start"]
