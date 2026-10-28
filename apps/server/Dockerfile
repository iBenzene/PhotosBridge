ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

WORKDIR /app
COPY package.json ./
RUN npm install

COPY . .
RUN npm run build

ENV PORT=8787
ENV DATABASE_PATH=/data/photos-bridge.sqlite
EXPOSE 8787
VOLUME ["/data"]
CMD ["npm", "start"]
