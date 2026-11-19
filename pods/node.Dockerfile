# The node pod: nodejs and npm (node, npm, npx), for nodejs projects. A plain dev
# image like the others in this directory; it runs only the programs broker.json lists.
ARG NODE_IMAGE=node:22-bookworm-slim
FROM ${NODE_IMAGE}
WORKDIR /work
